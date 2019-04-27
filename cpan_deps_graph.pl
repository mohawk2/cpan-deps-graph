#!/usr/bin/env perl
use 5.020;
use Mojolicious::Lite -signatures;
use CPAN::DistnameInfo;
use Cpanel::JSON::XS ();
use HTTP::Simple 'getjson';
use MetaCPAN::Client;
use Module::CoreList;
use Mojo::JSON qw(from_json to_json);
use Mojo::Redis;
use Mojo::URL;
use Syntax::Keyword::Try;
use version;
use lib::relative 'lib';

$HTTP::Simple::JSON = Cpanel::JSON::XS->new->utf8->allow_dupkeys;

plugin 'Config' => {file => app->home->child('cpan_deps_graph.conf')};

push @{app->commands->namespaces}, 'CPANDepsGraph::Command';

my $mcpan = MetaCPAN::Client->new;
helper mcpan => sub ($c) { $mcpan };

my $url = app->config->{redis_url};
my $redis = Mojo::Redis->new($url);
helper redis => sub ($c) { $redis };

helper phases => sub ($c) { +{map { ($_ => 1) } qw(configure build test runtime develop)} };
helper relationships => sub ($c) { +{map { ($_ => 1) } qw(requires recommends suggests)} };

helper retrieve_dist_deps => sub ($c, $dist) {
  return {} if $dist eq 'Acme-DependOnEverything'; # not happening
  my $mcpan = $c->mcpan;
  my $release;
  try { $release = $mcpan->release($dist) } catch { return {} }
  return {} unless defined $release->dependency and @{$release->dependency};
  my %deps_by_module;
  foreach my $dep (@{$release->dependency}) {
    next if $dep->{module} eq 'perl';
    next unless exists $c->phases->{$dep->{phase}};
    next unless exists $c->relationships->{$dep->{relationship}};
    push @{$deps_by_module{$dep->{module}}}, $dep;
  }
  my @modules = keys %deps_by_module;
  my @package_data;
  while (my @chunk = splice @modules, 0, 100) {
    my $url = Mojo::URL->new('https://cpanmeta.grinnz.com/api/v2/packages')
      ->query(module => \@chunk);
    push @package_data, @{getjson("$url")->{data}};
  }
  my %deps;
  foreach my $package (@package_data) {
    my $module = $package->{module} // next;
    my $path = $package->{path} // next;
    my $distname = CPAN::DistnameInfo->new($path)->dist;
    next if $distname eq 'perl';
    push @{$deps{$_->{phase}}{$_->{relationship}}}, {dist => $distname, module => $module, version => $_->{version}} for @{$deps_by_module{$module}};
  }
  return \%deps;
};

helper cache_dist_deps => sub ($c, $dist, $deps = undef) {
  $deps //= $c->retrieve_dist_deps($dist);
  my $redis = $c->redis->db;
  $redis->multi;
  foreach my $phase (keys %{$c->phases}) {
    foreach my $relationship (keys %{$c->relationships}) {
      my $key = "cpandeps:$dist:$phase:$relationship";
      $redis->del($key);
      my $modules = $deps->{$phase}{$relationship} // [];
      $redis->set($key, to_json $modules) if @$modules;
    }
  }
  $redis->set('cpandeps:last-update', time);
  $redis->exec;
};

helper cache_dist_deeply => sub ($c, $dist) {
  my %seen;
  my @to_check = $dist;
  while (defined(my $dist = shift @to_check)) {
    next if $seen{$dist}++;
    my $deps = $c->retrieve_dist_deps($dist);
    $c->cache_dist_deps($dist, $deps);
    foreach my $phase (keys %$deps) {
      foreach my $relationship (keys %{$deps->{$phase}}) {
        my $modules = $deps->{$phase}{$relationship};
        my %dists;
        $dists{$_->{dist}} = 1 for @$modules;
        push @to_check, keys %dists;
      }
    }
  }
};

helper get_dist_deps => sub ($c, $dist, $phases, $relationships, $perl_version = undef) {
  $perl_version = version->parse($perl_version)->numify if $perl_version;
  my $redis = $c->redis->db;
  my %all_deps;
  foreach my $phase (@$phases) {
    foreach my $relationship (@$relationships) {
      my $key = "cpandeps:$dist:$phase:$relationship";
      my $deps_json = $redis->get($key) // next;
      my $deps;
      try { $deps = from_json $deps_json } catch { next }
      foreach my $dep (@$deps) {
        try {
          next if Module::CoreList::is_core $dep->{module}, $dep->{version}, $perl_version;
        } catch {}
        $all_deps{$dep->{dist}} = 1;
      }
    }
  }
  return \%all_deps;
};

helper dist_dep_tree => sub ($c, $dist, $phases, $relationships, $perl_version = undef) {
  my %seen;
  my %deps;
  my @to_check = $dist;
  while (defined(my $dist = shift @to_check)) {
    next if $seen{$dist}++;
    $deps{$dist} = {};
    my $dist_deps = $c->get_dist_deps($dist, $phases, $relationships, $perl_version);
    foreach my $dist_dep (keys %$dist_deps) {
      $deps{$dist}{$dist_dep} = 1;
      push @to_check, $dist_dep;
    }
  }
  return \%deps;
};

helper dist_dep_graph => sub ($c, $dist, $phases, $relationships, $perl_version = undef) {
  my $tree = $c->dist_dep_tree($dist, $phases, $relationships, $perl_version);
  my @nodes = map {
    {distribution => $_, children => [sort keys %{$tree->{$_}}]}
  } sort keys %$tree;
  return \@nodes;
};

helper dist_dep_table => sub ($c, $dist, $phases, $relationships, $perl_version = undef) {
  my $tree = $c->dist_dep_tree($dist, $phases, $relationships, $perl_version);
  my %seen = ($dist => 1);
  my $parent = $dist;
  my @to_check = map { +{dist => $_, level => 1} } sort keys %{$tree->{$dist}};
  my @table;
  while (defined(my $dep = shift @to_check)) {
    my ($dist, $level) = @$dep{'dist','level'};
    push @table, {dist => $dist, level => $level};
    next if $seen{$dist}++;
    my @deps = sort keys %{$tree->{$dist}};
    unshift @to_check, map { +{dist => $_, level => $level+1} } @deps;
  }
  $c->app->log->debug(Mojo::Util::dumper \@table);
  return \@table;
};

get '/api/v1/deps' => sub ($c) {
  my $dist = $c->req->param('dist');
  my $phases = $c->req->every_param('phase');
  $phases = ['runtime'] unless @$phases;
  my $relationships = $c->req->every_param('relationship');
  $relationships = ['requires'] unless @$relationships;
  my $perl_version = $c->req->param('perl_version') // "$]";
  $c->render(json => $c->dist_dep_graph($dist, $phases, $relationships, $perl_version));
};

helper read_params => sub ($c) {
  $c->stash(dist => $c->req->param('dist'));
  $c->stash(style => $c->req->param('style'));
  $c->stash(phase => $c->req->param('phase'));
  $c->stash(recommends => $c->req->param('recommends'));
  $c->stash(suggests => $c->req->param('suggests'));
  $c->stash(perl_version => $c->req->param('perl_version'));
};

get '/' => sub ($c) { $c->redirect_to('graph') };
get '/graph' => sub ($c) { $c->read_params; $c->render };
get '/table' => sub ($c) {
  $c->read_params;
  return $c->render unless length(my $dist = $c->stash('dist'));
  my $phases = ['runtime'];
  my $phase = $c->stash('phase') // 'runtime';
  if ($phase eq 'build') {
    push @$phases, 'configure', 'build';
  } elsif ($phase eq 'test') {
    push @$phases, 'configure', 'build', 'test';
  } elsif ($phase eq 'configure') {
    $phases = ['configure'];
  }
  my $relationships = ['requires'];
  push @$relationships, 'recommends' if $c->stash('recommends');
  push @$relationships, 'suggests' if $c->stash('suggests');
  my $perl_version = $c->stash('perl_version') || "$]";
  $c->stash(deps => $c->dist_dep_table($dist, $phases, $relationships, $perl_version));
  $c->render;
};

app->start;
