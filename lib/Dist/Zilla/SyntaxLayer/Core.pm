package Dist::Zilla::SyntaxLayer::Core;

use Moose;
use MooseX::Types;

use namespace::autoclean;

has document => (
  is       => 'ro',
  isa      => class_type('PPI::Document'),
  required => 1,
  weak_ref => 1,
);

has logger => (
  is        => 'ro',
  handles   => [ qw(log log_debug log_fatal) ],
);

sub package_statements {
    my ($self) = @_;

    my $document = $self->document;
    my $packages = $document->find('PPI::Statement::Package');

    return () unless $packages;

    my %packages;
    foreach my $statement (@{$packages}){
        my $package = $statement->namespace;
        if ($statement->content =~ /package\s*(?:#.*)?\n\s*\Q$package/) {
          $self->log([ 'skipping private package %s in %s', $package, $document->logical_filename ]);
          next;
        }

      $packages{ $package } = $statement;
      }

    return %packages;
    }

1;
