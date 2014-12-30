package Dist::Zilla::Plugin::PkgVersion;
# ABSTRACT: add a $VERSION to your packages

use Moose;
with(
  'Dist::Zilla::Role::FileMunger',
  'Dist::Zilla::Role::FileFinderUser' => {
    default_finders => [ ':InstallModules', ':ExecFiles' ],
  },
  'Dist::Zilla::Role::PPI',
);

use namespace::autoclean;

=head1 SYNOPSIS

in dist.ini

  [PkgVersion]

=head1 DESCRIPTION

This plugin will add lines like the following to each package in each Perl
module or program (more or less) within the distribution:

  $MyModule::VERSION = '0.001';

or

  { our $VERSION = '0.001'; }

...where 0.001 is the version of the dist, and MyModule is the name of the
package being given a version.  (In other words, it always uses fully-qualified
names to assign versions.)

It will skip any package declaration that includes a newline between the
C<package> keyword and the package name, like:

  package
    Foo::Bar;

This sort of declaration is also ignored by the CPAN toolchain, and is
typically used when doing monkey patching or other tricky things.

=attr die_on_existing_version

If true, then when PkgVersion sees an existing C<$VERSION> assignment, it will
throw an exception rather than skip the file.  This attribute defaults to
false.

=attr die_on_line_insertion

By default, PkgVersion look for a blank line after each C<package> statement.
If it finds one, it inserts the C<$VERSION> assignment on that line.  If it
doesn't, it will insert a new line, which means the shipped copy of the module
will have different line numbers (off by one) than the source.  If
C<die_on_line_insertion> is true, PkgVersion will raise an exception rather
than insert a new line.

=attr use_our

The idea here was to insert C<< { our $VERSION = '0.001'; } >> instead of C<<
$Module::Name::VERSION = '0.001'; >>.  It turns out that this causes problems
with some analyzers.  Use of this feature is deprecated.

Something else will replace it in the future.

=attr finder

=for stopwords FileFinder

This is the name of a L<FileFinder|Dist::Zilla::Role::FileFinder> for finding
modules to edit.  The default value is C<:InstallModules> and C<:ExecFiles>;
this option can be used more than once.

Other predefined finders are listed in
L<Dist::Zilla::Role::FileFinderUser/default_finders>.
You can define your own with the
L<[FileFinder::ByName]|Dist::Zilla::Plugin::FileFinder::ByName> and
L<[FileFinder::Filter]|Dist::Zilla::Plugin::FileFinder::Filter> plugins.

=cut

sub BUILD {
  my ($self) = @_;
  $self->log("use_our option to PkgVersion is deprecated and will be removed")
    if $self->use_our;
}

sub munge_files {
  my ($self) = @_;

  $self->munge_file($_) for @{ $self->found_files };
}

sub munge_file {
  my ($self, $file) = @_;

  if ($file->is_bytes) {
    $self->log_debug($file->name . " has 'bytes' encoding, skipping...");
    return;
  }

  return $self->munge_perl($file);
}

has die_on_existing_version => (
  is  => 'ro',
  isa => 'Bool',
  default => 0,
);

has die_on_line_insertion => (
  is  => 'ro',
  isa => 'Bool',
  default => 0,
);

has use_our => (
  is  => 'ro',
  isa => 'Bool',
  default => 0,
);

sub strip_tokens_leading_whitespace {
    my ($self, $tokens) = @_;

    shift @$tokens while @$tokens && $tokens->[0]->isa('PPI::Token::Whitespace');
    }

sub strip_tokens_for_module_version {
    my ($self, $tokens) = @_;

    $self->strip_tokens_leading_whitespace( $tokens );

    my $version;
    my $next = $tokens->[0];

    # Fairly lax if it's a Number::Float or a Number::Version
    if ($next && $next->isa('PPI::Token::Number')){
        $version = $next->literal;

        # Remove it from the tree
        shift @$tokens;
        }

    return $version;
    }

sub parse_tokens_for_module_string {
    my ($self, $tokens) = @_;

    $self->strip_tokens_leading_whitespace( $tokens );

    my $next = shift @$tokens;
    return unless $next && $next->isa('PPI::Token::Word');

    my $module_name = $next->literal;

    $self->strip_tokens_for_module_version($tokens);

    return $module_name;
    }

sub parse_tokens_for_class_attributes {
    my ($self, $tokens) = @_;

    $self->strip_tokens_leading_whitespace( $tokens );

    while (my $next = $tokens->[0]){
        if ($next->isa('PPI::Token::Word') && $next->literal =~ m#^with|extends$#){
            shift @$tokens;

            $self->parse_tokens_for_module_string( $tokens );
            next;
            }
        last;
        }
    return;
    }

sub parse_tokens_for_class_statement {
    my ($self, $tokens) = @_;

    my $first = shift @$tokens;

    return unless $first && $first->isa('PPI::Token::Word') && $first->literal eq 'class';

    my $module = $self->parse_tokens_for_module_string( $tokens );

    return unless $module;

    # This is really just a token stripper. We care only about what comes after
    $self->parse_tokens_for_class_attributes( $tokens );

    $self->strip_tokens_leading_whitespace( $tokens );

    my $block = shift @$tokens;
    return unless $block && $block->isa('PPI::Structure::Block');

    return $module => $block->child(0);
    }

sub parse_document_for_moops_classes {
    my ($self, $document) = @_;

    return () unless $document->find(sub {
      $_[1]->isa('PPI::Statement::Include') &&
      $_[1]->module('Moops');
      });

    my %classes;

    $document->find(sub {
      return unless $_[1]->isa('PPI::Statement');

      my ($module, $block) = $self->parse_tokens_for_class_statement( [ $_[1]->children ] );

      if ($module){
        $classes{$module} = $block;
        }

      # We're using this like a wanted, so no need to care about catching anything
      return 0;
      });

    return %classes;
    }

sub parse_document_package_statements {
    my ($self, $document) = @_;

    my $packages = $document->find('PPI::Statement::Package');

    return () unless $packages;

    my %packages;
    for my $statement (@$packages){
        my $package = $statement->namespace;
        if ($statement->content =~ /package\s*(?:#.*)?\n\s*\Q$package/) {
          $self->log([ 'skipping private package %s in %s', $package, $document->filename ]);
          next;
        }

      $packages{ $package } = $statement;
      }

    return %packages;
    }

sub munge_perl {
  my ($self, $file) = @_;

  my $version = $self->zilla->version;

  require version;
  Carp::croak("invalid characters in version")
    unless version::is_lax($version);

  my $document = $self->ppi_document_for_file($file);

  my %package_statements = (
    $self->parse_document_package_statements( $document ),
    $self->parse_document_for_moops_classes( $document )
    );

  unless (%package_statements){
    $self->log_debug([ 'skipping %s: no package statement found', $file->name ]);
    return;
  }

  if ($self->document_assigns_to_variable($document, '$VERSION')) {
    if ($self->die_on_existing_version) {
      $self->log_fatal([ 'existing assignment to $VERSION in %s', $file->name ]);
    }

    $self->log([ 'skipping %s: assigns to $VERSION', $file->name ]);
    return;
  }

  my %seen_pkg;

  my $munged = 0;
  for my $package (keys %package_statements) {
    my $stmt = $package_statements{ $package };

    if ($seen_pkg{ $package }++) {
      $self->log([ 'skipping package re-declaration for %s', $package ]);
      next;
    }

    $self->log("non-ASCII package name is likely to cause problems")
      if $package =~ /\P{ASCII}/;

    $self->log("non-ASCII version is likely to cause problems")
      if $version =~ /\P{ASCII}/;

    # the \x20 hack is here so that when we scan *this* document we don't find
    # an assignment to version; it shouldn't be needed, but it's been annoying
    # enough in the past that I'm keeping it here until tests are better
    my $trial = $self->zilla->is_trial ? ' # TRIAL' : '';
    my $perl = $self->use_our
        ? "{ our \$VERSION\x20=\x20'$version'; }$trial"
        : "\$$package\::VERSION\x20=\x20'$version';$trial";

    $self->log_debug([
      'adding $VERSION assignment to %s in %s',
      $package,
      $file->name,
    ]);

    my $blank;

    {
      my $curr = $stmt;
      while (1) {
        # avoid bogus locations due to insert_after
        $document->flush_locations if $munged;

        my $curr_line_number = $curr->line_number + ( $curr->can('lines') ? $curr->lines : 1 );
        my $find = $document->find(sub {
          my $line = $_[1]->line_number;
          return $line > $curr_line_number ? undef : $line == $curr_line_number;
        });

        last unless $find and @$find == 1;

        if ($find->[0]->isa('PPI::Token::Comment') || $find->[0]->isa('PPI::Token::Pod') ) {
          $curr = $find->[0];
          next;
        }

        if ("$find->[0]" =~ /\A\s*\z/) {
          $blank = $find->[0];
        }

        last;
      }
    }

    $perl = $blank ? "$perl\n" : "\n$perl";

    # Why can't I use PPI::Token::Unknown? -- rjbs, 2014-01-11
    my $bogus_token = PPI::Token::Comment->new($perl);

    if ($blank) {
      Carp::carp("error inserting version in " . $file->name)
        unless $blank->insert_after($bogus_token);
      $blank->delete;
    } else {
      my $method = $self->die_on_line_insertion ? 'log_fatal' : 'log';
      $self->$method([
        'no blank line for $VERSION after package %s statement in %s line %s',
        $stmt->namespace,
        $file->name,
        $stmt->line_number,
      ]);

      Carp::carp("error inserting version in " . $file->name)
        unless $stmt->insert_after($bogus_token);
    }

    $munged = 1;
  }

  # the document is no longer correct; it must be reparsed before it can be used again
  $file->encoded_content($document->serialize) if $munged;
}

__PACKAGE__->meta->make_immutable;
1;

=head1 SEE ALSO

Core Dist::Zilla plugins:
L<PodVersion|Dist::Zilla::Plugin::PodVersion>,
L<AutoVersion|Dist::Zilla::Plugin::AutoVersion>,
L<NextRelease|Dist::Zilla::Plugin::NextRelease>.

Other Dist::Zilla plugins:
L<OurPkgVersion|Dist::Zilla::Plugin::OurPkgVersion> inserts version
numbers using C<our $VERSION = '...';> and without changing line numbers

=cut
