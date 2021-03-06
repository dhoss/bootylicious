#!/usr/bin/env perl

use Mojolicious::Lite;
use Mojo::Date;
use Pod::Simple::HTML;
require Time::Local;

my %config = (
    name  => $ENV{BOOTYLICIOUS_USER}  || 'whoami',
    email => $ENV{BOOTYLICIOUS_EMAIL} || '',
    title => $ENV{BOOTYLICIOUS_TITLE} || 'I am too lazy to set the title',
    about => $ENV{BOOTYLICIOUS_ABOUT} || 'What?',
    description => $ENV{BOOTYLICIOUS_DESCR} || 'I do not know if I need this',
    articles_dir => $ENV{BOOTYLICIOUS_ARTICLESDIR} || 'articles',
    public_dir => $ENV{BOOTYLICIOUS_PUBLICDIR} || 'public',
);

get '/' => 'index' => sub {
    my $c = shift;

    my $article;
    my @articles = _parse_articles($c, limit => 10);

    if (@articles) {
        $article = $articles[0];
    }

    $c->stash(config => \%config, article => $article, articles => \@articles);
};

get '/articles' => 'articles' => sub {
    my $c = shift;

    my $root = $c->app->home;

    my $last_modified = Mojo::Date->new;

    my @articles = _parse_articles($c, limit => 0);
    if (@articles) {
        $last_modified = $articles[0]->{mtime};

        #return 1 unless _is_modified($c, $last_modified);
    }

    $c->res->headers->header('Last-Modified' => $last_modified);

    $c->stash(articles => \@articles, last_modified => $last_modified, config => \%config);
};

get '/articles/:year/:month/:day/:alias' => 'article' => sub {
    my $c = shift;

    my $root = $c->app->home->rel_dir($config{articles_dir});
    my $path = join('/',
        $root,
        $c->stash('year')
          . $c->stash('month')
          . $c->stash('day') . '-'
          . $c->stash('alias')
          . '.pod');

    return $c->app->static->serve_404($c) unless -r $path;

    my $last_modified = Mojo::Date->new((stat($path))[9]);

    my $data; $data = _parse_article($c, $path)
        or return $c->app->static->serve_404($c);

    #return 1 unless _is_modified($c, $last_modified);

    $c->stash(article => $data, template => 'article', config => \%config);

    #$c->res->headers->header('Last-Modified' => Mojo::Date->new($last_modified));
};

sub makeup {
    my $public_dir = app->home->rel_dir($config{public_dir});

    # CSS, JS auto import
    foreach my $type (qw/css js/) {
        $config{$type} = [map {s/^$public_dir\///; $_} glob("$public_dir/*.$type")];
    }
}

sub _is_modified {
    my $c = shift;
    my ($last_modified) = @_;

    my $date = $c->req->headers->header('If-Modified-Since');
    return 1 unless $date;

    return 1 unless Mojo::Date->new($date)->epoch == $last_modified->epoch;

    $c->res->code(304);

    return 0;
}

sub _parse_articles {
    my $c = shift;
    my %params = @_;

    my @files =
      sort { $b cmp $a }
      glob(app->home->rel_dir($config{articles_dir}) . '/*.pod');

    @files = splice(@files, 0, $params{limit}) if $params{limit};

    my @articles;
    foreach my $file (@files) {
        my $data = _parse_article($c, $file);
        next unless $data && %$data;

        push @articles, $data;
    }

    return @articles;
}

my %_articles;
sub _parse_article {
    my $c = shift;
    my $path = shift;

    return unless $path;

    return $_articles{$path} if $_articles{$path};

    unless ($path =~ m/\/(\d\d\d\d)(\d\d)(\d\d)-(.*?)\.pod$/) {
        $c->app->log->debug("Ignoring $path: unknown file");
        return;
    }
    my ($year, $month, $day, $name) = ($1, $2, $3, $4);

    my $epoch = 0;
    eval { $epoch = Time::Local::timegm(0, 0, 0, $day, $month - 1, $year - 1900); };
    if ($@ || $epoch < 0) {
        $c->app->log->debug("Ignoring $path: wrong timestamp");
        return;
    }

    my $parser = Pod::Simple::HTML->new;

    $parser->force_title('');
    $parser->html_header_before_title('');
    $parser->html_header_after_title('');
    $parser->html_footer('');

    my $title = '';
    my $content = '';;

    $parser->output_string(\$content);
    eval { $parser->parse_file($path) };
    if ($@) {
        $c->app->log->debug("Ignoring $path: parser error");
        return;
    }

    # Hacking
    $content =~ s|<a name='___top' class='dummyTopAnchor'\s*></a>\n||g;
    $content =~ s/<a class='u'.*?name=".*?"\s*>(.*?)<\/a>/$1/sg;
    $content =~ s|^\n<h1>NAME</h1>\s*<p>(.*?)</p>||sg;
    $title = $1 || $name;

    return $_articles{$path} = {
        title   => $title,
        content => $content,
        mtime   => Mojo::Date->new((stat($path))[9]),
        created => Mojo::Date->new($epoch),
        year    => $year,
        month   => $month,
        day     => $day,
        name    => $name
    };
}

app->types->type(rss => 'application/rss+xml');

makeup;

shagadelic;

__DATA__

@@ index.html.eplite
% my $self = shift;
% $self->stash(layout => 'wrapper');
% if (my $article = $self->stash('article')) {
    <h1><%= $article->{title} %></h1>
    <div class="created"><%= $article->{created} %></div>
    <div class="pod"><%= $article->{content} %></div>
    <h2>Last articles</h2>
    <ul>
% foreach my $article (@{$self->stash('articles')}) {
        <li>
            <a href="<%== $self->url_for('article', year => $article->{year}, month => $article->{month}, day => $article->{day}, alias => $article->{name}) %>.html"><%= $article->{title} %></a><br />
            <%= $article->{created} %>
        </li>
% }
    </ul>
% }
% else {
Not much here yet :(
% }

@@ articles.html.eplite
% my $self = shift;
% $self->stash(layout => 'wrapper');
% my $articles = $self->stash('articles');
% my $tmp;
% my $new = 0;
% foreach my $article (@$articles) {
%     if (!$tmp || $article->{year} ne $tmp->{year}) {
    <%= "</ul>" if $tmp %>
    <b><%= $article->{year} %></b>
<ul>
%     }

    <li>
        <a href="<%== $self->url_for('article', year => $article->{year}, month => $article->{month}, day => $article->{day}, alias => $article->{name}) %>.html"><%= $article->{title} %></a><br />
        <%= $article->{created} %>
    </li>

%     $tmp = $article;
% }

@@ index.rss.eplite
% my $self = shift;
% my $articles = $self->stash('articles');
% my $last_modified = $self->stash('last_modified');
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xml:base="<%= $self->req->url->base %>"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title><%= $self->stash('config')->{title} %></title>
        <link><%= $self->req->url->base %></link>
        <description><%= $self->stash('config')->{description} %></description>
        <pubDate><%= $last_modified %></pubDate>
        <lastBuildDate><%= $last_modified %></lastBuildDate>
        <generator>Mojolicious::Lite</generator>
    </channel>
% foreach my $article (@$articles) {
% my $link = $self->url_for('article', article => $article->{name}, format => 'html')->to_abs;
    <item>
      <title><%== $article->{title} %></title>
      <link><%= $link %></link>
      <description><%== $article->{content} %></description>
      <pubDate><%= $article->{mtime} %></pubDate>
      <guid><%= $link %></guid>
    </item>
% }
</rss>

@@ article.html.eplite
% my $self = shift;
% $self->stash(layout => 'wrapper');
% my $article = $self->stash('article');
<h1><%= $article->{title} %></h1>
<div class="created"><%= $article->{created} %></div>
<div class="pod"><%= $article->{content} %></div>

@@ layouts/wrapper.html.eplite
% my $self = shift;
% my $config = $self->stash('config');
<!html>
    <head>
        <title><%= $config->{title} %></title>
% foreach my $file (@{$config->{css}}) {
        <link rel="stylesheet" href="/<%= $file %>" type="text/css" />
% }
% if (!@{$config->{css}}) {
        <style type="text/css">
            #body {width:65%;margin:auto}
            #header {margin:1em 0em}
            #menu {margin:1em 0em;text-align:right}
            #about {border-top:3px solid #ccc;border-bottom:3px solid #ddd;text-align:center;padding:1em 0em}
            .created {font-size:small;padding-bottom:1em}
            .pod h1 {font-size: 110%}
            .pod h2 {font-size: 105%}
            .pod h3 {font-size: 100%}
            .pod h4 {font-size: 95%}
            .pod h5 {font-size: 90%}
            .pod h6 {font-size: 85%}
            #footer {}
        </style>
% }
        <link rel="alternate" type="application/rss+xml" title="<%= $config->{title} %>" href="<%= $self->url_for('articles', format => 'rss') %>" />
    </head>
    <body>
        <div id="body">
            <div id="header"><%= $config->{name} %>: <%= $config->{title} %></h1></div>
            <div id="about"><%= $config->{about} %></div>
            <div id="menu">
                <a href="<%= $self->url_for('index', format => '') %>">index</a>
                <a href="<%= $self->url_for('articles') %>">archive</a>
            </div>

            <div id="content">
            <%= $self->render_inner %>
            </div>

            <div id="footer"><small>Powered by Mojolicious::Lite & Pod::Simple::HTML</small></div>
        </div>
% foreach my $file (@{$config->{js}}) {
        <script type="text/javascript" href="/<%= $file %>" />
% }
    </body>
</html>

__END__

=head1 NAME

Bootylicious -- one-file blog on Mojo steroids!

=head1 SYNOPSIS

    $ perl bootylicious.pl daemon

=head1 DESCRIPTION

Bootylicious is a minimalistic blogging application built on
L<Mojolicious::Lite>. You start with just one file, but it is easily extendable
when you add new templates, css files etc.

=head1 CONFIGURATION

=head1 FILESYSTEM

All the articles must be stored in BOOTYLICIOUS_ARTICLESDIR directory with a
name like 20090730-my-new-article.pod. They are parsed with
L<Pod::Simple::HTML>.

=head1 TEMPLATES

Embedded templates will work just fine, but when you want to have something more
advanced just create a template in templates/ directory with the same name but
with a different extension.

For example there is index.html.eplite, thus templates/index.html.epl should be
created with a new content.

=head1 DEVELOPMENT

=head2 Repository

    http://github.com/vti/bootylicious/commits/master

=head1 SEE ALSO

L<Mojo> L<Mojolicious> L<Mojolicious::Lite>

=head1 AUTHOR

Viacheslav Tikhanovskii, C<vti@cpan.org>.

=head1 COPYRIGHT

Copyright (C) 2008-2009, Viacheslav Tikhanovskii.

This program is free software, you can redistribute it and/or modify it under
the same terms as Perl 5.10.

=cut
