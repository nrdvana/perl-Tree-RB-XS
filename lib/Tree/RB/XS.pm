package Tree::RB::XS;

# VERSION
# ABSTRACT: Similar API to Tree::RB implemented in C

use strict;
use warnings;
require XSLoader;
XSLoader::load('Tree::RB::XS', $Tree::RB::XS::VERSION);
use Exporter 'import';
our @EXPORT_OK= qw( KEY_TYPE_ANY KEY_TYPE_INT KEY_TYPE_FLOAT KEY_TYPE_BSTR KEY_TYPE_USTR );

=head1 SYNOPSIS

  my $tree= Tree::RB::XS->new;
  $tree->put(a => 1);
  say $tree->get('a');
  $tree->delete('a');
  
  # optimize for integer comparisons
  $tree= Tree::RB::XS->new(key_type => KEY_TYPE_INT);
  $tree->put(1 => "x");

  # optimize for floating-point comparisons
  $tree= Tree::RB::XS->new(key_type => KEY_TYPE_FLOAT);
  $tree->put(0.125 => "x");

  # optimize for byte strings
  $tree= Tree::RB::XS->new(key_type => KEY_TYPE_BSTR);
  $tree->put("test" => "x");
  
  # inspect the node objects
  say $tree->min->key;
  say $tree->nth(0)->key;
  my $node= $tree->min;
  my $next= $node->next;
  $node->prune;

=head1 DESCRIPTION

This module is similar to L<Tree::RB> but implemented in C for speed.

=head1 CONSTRUCTOR

=head2 new

  my $tree= Tree::RB::XS->new( %OPTIONS );
                     ...->new( \&compare_fn );

Options:

=over

=item key_type

This chooses how keys will be stored in this tree: C<KEY_TYPE_ANY> (the default),
C<KEY_TYPE_INT>, C<KEY_TYPE_FLOAT>, C<KEY_TYPE_BSTR>, or C<KEY_TYPE_USTR>.
Integers are of course the most efficient, followed by floats, followed by
byte-strings and unicode-strings, followed by 'ANY' (which stores a whole
perl scalar).  BSTR and USTR both save an internal copy of your key, so
might be a bad idea if your keys are extremely large and nodes are frequently
added to the tree.  The difference between BSTR and USTR is in how the bytes
are initially copied out of the key during C</insert>, the former as raw bytes
and the latter as UTF8 bytes.

If the C<compare_fn> is a Perl coderef, this is forced to C<KEY_TYPE_ANY>.
(it is best for performance to store a whole perl scalar if they are going
to be passed to your comparison function over and over and over).

=item compare_fn

A coderef that compares its parameters in the same manner as C<cmp>.

If specified as a perl coderef, this forces C<< key_type => KEY_TYPE_ANY >>,
since calling your callback over and over is most efficient if the scalars
are stored as scalars.  Beware that using a custom coderef throws away most
of the speed gains from using this XS variant over plain L<Tree::RB>.

If not provided, the default comparison for ANY uses perl's own C<cmp>
operator, the default for BSTR and USTR are C's C<memcmp> function,
and INT and FLOAT are the obvious numeric comparisons.  memcmp does not give
correct unicode sorting, of course, but it's fast.

TODO: It would be neat to have a collection of enumerated XS comparison
functions available to choose from, to get custom behavior without the
performance hit of a coderef callback.

=back

=cut

sub new {
	my $class= shift;
	my %options= @_ == 1 && ref $_[0] eq 'CODE'? ( compare_fn => $_[0] ) : @_;
	my $self= bless \%options, $class;
	$self->_init_tree($self->key_type, $self->compare_fn);
	$self->allow_duplicates(1) if delete $self->{allow_duplicates};
	$self;
}

=head1 ATTRIBUTES

=head2 key_type

=head2 compare_fn

The optional coderef that will be called each time keys need compared.

=cut

sub key_type { $_[0]{key_type} || KEY_TYPE_ANY() }
sub compare_fn { $_[0]{compare_fn} }

=head2 allow_duplicates

Boolean, read/write.  Controls whether L</insert> will allow additional nodes with
keys that already exist in the tree.  This does not change the behavior of L</put>,
only L</insert>.  If you set this to false, it does not remove duplicates that
already existed.  The initial value is false.

=head2 size

Returns the number of elements in the tree.

=head1 METHODS

=head2 get

  my $val= $tree->get($key);

Fetch a value form the tree, by its key.  Unlike L<Tree::RB/get>, this always
returns a single value, regardless of list context, and does not accept options
for how to find nearby keys.

=head2 get_node

Same as L</get>, but returns the node instead of the value.

=head2 put

  my $old_val= $tree->put($key, $new_val);

Associate the key with a new value.  If the key previously existed, this returns
the old value, and updates the tree to reference the new value.  If the tree
allows duplicate keys, this will replace all nodes having this key.

=head2 delete

  my $count= $tree->delete($key);

Delete any node with a key identical to C<$key>, and return the number of nodes
removed.  (This will only return 0 or 1, unless you enable duplicate keys.)

=head2 insert

Insert a new node into the tree, and return the index at which it was inserted.
If the node already existed, this returns -1 and does not change the tree.

=head2 min_node

Get the tree node with minimum key.  Returns undef if the tree is empty.

Alias: C<min>

=head2 max_node

Get the tree node with maximum key.  Returns undef if the tree is empty.

Alias: C<max>

=head2 nth_node

Get the Nth node in the sequence from min to max.  N is a zero-based index.
You may use negative numbers to count down form max.

Alias: C<nth>

=cut

*min= *min_node;
*max= *max_node;
*nth= *nth_node;

=head1 NODE OBJECTS

The nodes returned by the methods above have the following attributes:

=over 10

=item key

The sort key.  Read-only, but if you supplied a reference and you modify what it
points to, you will break the sorting of the tree.

=item value

The data associated with the node.  Read/Write.

=item prev

The previous node in the sequence of keys.

=item next

The next node in the sequence of keys.

=item left

The left sub-tree.

=item right

The right sub-tree.

=item parent

The parent node, if any.

=item color

0 = black, 1 = red.

=item count

The number of items in the tree rooted at this node (inclusive)

=back

And the following methods:

=over 10

=item prune

Remove this single node from the tree.  The node will still have its key and value,
but all attributes linking to other nodes will become C<undef>.

=back

=head1 EXPORTS

=over

=item KEY_TYPE_ANY

=item KEY_TYPE_INT

=item KEY_TYPE_FLOAT

=item KEY_TYPE_BSTR

=item KEY_TYPE_USTR

=back

=cut

1;
