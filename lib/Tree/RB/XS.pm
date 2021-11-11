package Tree::RB::XS;

# VERSION
# ABSTRACT: Similar API to Tree::RB implemented in C

use strict;
use warnings;
require XSLoader;
XSLoader::load('Tree::RB::XS', $Tree::RB::XS::VERSION);
use Exporter 'import';
our @EXPORT_OK= qw( KEY_TYPE_ANY KEY_TYPE_INT KEY_TYPE_FLOAT KEY_TYPE_STR );

=head1 SYNOPSIS

  my $tree= Tree::RB::XS->new;
  $tree->put(a => 1);
  $tree->put(b => 2);

=head1 DESCRIPTION

This module is similar to L<Tree::RB> but implemented in C for speed.

=head1 CONSTRUCTOR

=head2 new

  my $tree= Tree::RB::XS->new( %OPTIONS );
                     ...->new( \&compare_fn );

Options:

=over

=item compare_fn

A coderef that compares its parameters in the same manner as C<cmp>.

=item key_type

One of C<KEY_TYPE_STR> (the default), C<KEY_TYPE_INT>, or C<KEY_TYPE_ANY>.
These are constants, exported by this module.  Integers are of course the
most efficient, followed by strings, followed by 'ANY'.  Any means any perl
scalar or reference, and for that you either need to specify a C<compare>
coderef, or overload the 'cmp' operator for your key objects.

=back

=cut

sub new {
	my $class= shift;
	my %options= @_ == 1 && ref $_[0] eq 'CODE'? ( compare_fn => $_[0] ) : @_;
	my $self= bless \%options, $class;
	$self->_init_tree($self->key_type, $self->compare_fn);
	$self;
}

=head1 ATTRIBUTES

=head2 compare_fn

The optional coderef that will be called each time keys need compared.

=cut

sub key_type { $_[0]{key_type} || Tree::RB::XS::KEY_TYPE_STR() }
sub compare_fn { $_[0]{compare_fn} }

=head1 EXPORTS

=over

=item KEY_TYPE_ANY

=item KEY_TYPE_INT

=item KEY_TYPE_FLOAT

=item KEY_TYPE_STR

=back

=cut

1;
