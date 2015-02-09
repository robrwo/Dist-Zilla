package Dist::Zilla::SyntaxLayer::Moops;

use Moose;
extends 'Dist::Zilla::SyntaxLayer::Core';

use namespace::autoclean;

around package_statements => sub {
    my ($next, $self) = @_;

    my %packages = $self->$next;

    my $document = $self->document;

    my $is_moops = $document->find(sub {
            $_[1]->isa('PPI::Statement::Include') &&
            $_[1]->module('Moops');
          });

    if ($is_moops) {

      $document->find(sub {
          return unless $_[1]->isa('PPI::Statement');

          my ($module, $block) = $self->parse_tokens_for_class_statement( [ $_[1]->children ] );

          if ($module){
            $packages{$module} = $block;
          }

          # We're using this like a wanted, so no need to care about catching anything
          return 0;
        });

    }

    return %packages;
};


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

    return unless $first && $first->isa('PPI::Token::Word') && $first->literal =~ /^(?:class|role)$/;

    my $module = $self->parse_tokens_for_module_string( $tokens );

    return unless $module;

    # This is really just a token stripper. We care only about what comes after
    $self->parse_tokens_for_class_attributes( $tokens );

    $self->strip_tokens_leading_whitespace( $tokens );

    my $block = shift @$tokens;
    return unless $block && $block->isa('PPI::Structure::Block');

    return $module => $block->child(0);
    }


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


1;
