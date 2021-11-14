package Tree::RB::XS;

# VERSION
# ABSTRACT: Similar API to Tree::RB implemented in C

use strict;
use warnings;
use Carp;
require XSLoader;
XSLoader::load('Tree::RB::XS', $Tree::RB::XS::VERSION);
use Exporter 'import';
our @_key_types= qw( KEY_TYPE_ANY KEY_TYPE_INT KEY_TYPE_FLOAT KEY_TYPE_BSTR KEY_TYPE_USTR );
our @_cmp_enum= qw( CMP_PERL CMP_INT CMP_FLOAT CMP_MEMCMP CMP_UTF8 );
our @_lookup_modes= qw( LU_EQ LU_GT LU_LT LU_GE LU_LE LU_NEXT LU_PREV
                        LUEQUAL LUGTEQ LULTEQ LUGREAT LULESS LUNEXT LUPREV );
our @EXPORT_OK= (@_key_types, @_cmp_enum, @_lookup_modes);
our %EXPORT_TAGS= (
	key_type => \@_key_types,
	cmp      => \@_cmp_enum,
	lookup   => \@_lookup_modes,
);

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
                     ...->new( sub($a,$b) { $a cmp $b });

Options:

=over

=item L</key_type>

Choose an optimized storage for keys.  The default is L</KEY_TYPE_ANY>.

=item L</compare_fn>

Choose a custom key-compare function.  The default depends on C<key_type>.
If this is a perl coderef, the C<key_type> is forced to be L</KEY_TYPE_ANY>.

=item L</allow_duplicates>

Whether to allow two nodes with the same key.  Defaults to false.

=item L</compat_list_context>

Whether to enable full compatibility with L<Tree::RB>'s list-context behaviors.
Defaults to false.

=back

=cut

sub new {
	my $class= shift;
	my %options= @_ == 1 && ref $_[0] eq 'CODE'? ( compare_fn => $_[0] ) : @_;
	my $self= bless \%options, $class;
	$self->_init_tree(delete $self->{key_type}, delete $self->{compare_fn});
	$self->allow_duplicates(1) if delete $self->{allow_duplicates};
	$self->compat_list_context(1) if delete $self->{compat_list_context};
	$self;
}

=head1 ATTRIBUTES

=head2 key_type

The key-storage strategy used by the tree.  Read-only; pass as an option to
the constructor.

This is one of the following values: L</KEY_TYPE_ANY>, L</KEY_TYPE_INT>,
L</KEY_TYPE_FLOAT>, L</KEY_TYPE_BSTR>, or L</KEY_TYPE_USTR>.
See the description in EXPORTS for full details on each.

Integers are of course the most efficient, followed by floats, followed by
byte-strings and unicode-strings, followed by 'ANY' (which stores a whole
perl scalar).  BSTR and USTR both save an internal copy of your key, so
might be a bad idea if your keys are extremely large and nodes are frequently
added to the tree.

=head2 compare_fn

Specifies the function that compares keys.  Read-only; pass as an option to
the constructor.

This is one of: L</CMP_PERL>, L</CMP_INT>, L</CMP_FLOAT>, L</CMP_MEMCMP>,
L</CMP_UTF8>, or a coderef.

If given as a perl coderef, it should take two parameters and return an integer
indicating their order in the same manner as Perl's C<cmp>.
Note that this forces C<< key_type => KEY_TYPE_ANY >>.
Beware that using a custom coderef throws away most of the speed gains from using
this XS variant over plain L<Tree::RB>.

If not provided, the default comparison is chosen to match the C<key_type>,
with the defult C<KEY_TYPE_ANY> using Perl's own C<cmp> comparator.

Patches welcome, for anyone who wants to expand the list of optimized built-in
comparison functions.

=head2 allow_duplicates

Boolean, read/write.  Controls whether L</insert> will allow additional nodes with
keys that already exist in the tree.  This does not change the behavior of L</put>,
only L</insert>.  If you set this to false, it does not remove duplicates that
already existed.  The initial value is false.

=head2 compat_list_context

Boolean, read/write.  Controls whether C</get> returns multiple values in list context.
I wanted to match the API of L<Tree::RB>, but I can't bring myself to make an innocent-named
method like 'get' change its behavior in list context.  So, by deault, this attribute is
false and 'get' always returns a scalar.  But if you set this to true, C<get> changes in
list context to also return the Node, like is done in C<Tree::RB>.

=head2 size

Returns the number of elements in the tree.

=head1 METHODS

=head2 get

  my $val= $tree->get($key);

Fetch a value form the tree, by its key.  Unlike L<Tree::RB/get>, this always
returns a single value, regardless of list context, and does not accept options
for how to find nearby keys.

=head2 get_all

  my @values= $tree->get_all($key);

If you L</allow_duplicates>, this method is useful to return the values of all
nodes that match the key.  This can be more efficient than stepping node-to-node
for small numbers of duplicates, but beware that large numbers of duplicate could
have an adverse affect on Perl's stack.

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

=head2 Key Types

Export all with ':key_type';

=over

=item KEY_TYPE_ANY

This C<key_type> causes the tree to store whole Perl scalars for each node.
Its default comparison function is Perl's own C<cmp> operator.

=item KEY_TYPE_INT

This C<key_type> causes the tree to store keys as Perl's integers,
which are either 32-bit or 64-bit depending on how Perl was compiled.
Its default comparison function puts the numbers in non-decreasing order.

=item KEY_TYPE_FLOAT

This C<key_type> causes the tree to store keys as Perl's floating point type,
which are either 64-bit doubles or 80-bit long-doubles.
Its default comparison function puts the numbers in non-decreasing order.

=item KEY_TYPE_BSTR

This C<key_type> causes the tree to store keys as byte strings.
The default comparison function is the standard Libc C<memcmp>.

=item KEY_TYPE_USTR

Same as C<KEY_TYPE_BSTR> but reads the bytes from the supplied key as UTF-8 bytes.
The default comparison function is also C<memcmp> even though this does not sort
Unicode correctly.  (for correct unicode, use C<KEY_TYPE_ANY>, but it's slower...)

=back

=head2 Lookup Mode

Export all with ':lookup'

=over

=item LU_EQ

Return an exact match.  If duplicate keys are present, this returns the
first (leftmost) of the matching nodes.
Has alias C<LUEQUAL> to match Tree::RB.

=item LU_GE

Return the first exact match, or the first node greater than the key,
or C<undef> if the key is greater than any node.
Has alias C<LUGTEQ> to match Tree:RB.

=item LU_LE

Return the first exact match, or the last node less than the key,
Return the key is less than any node.
Has alias C<LULTEQ> to match Tree::RB.

=item LU_GT

Return the first node greater than the key,
or C<undef> if the key is greater than any node.
Has alias C<LUGREAT> to match Tree::RB.

=item LU_LT

Return the last node less than the key,
Return the key is less than any node.
Has alias C<LULESS> to match Tree::RB.

=item LU_NEXT

Look for the last node matching the specified key (returning C<undef> if not found)
then return C<< $node->next >>.  This is the same as C<LU_GT> except it ensures the
key existed.
Has alias C<LUNEXT> to match Tree::RB.

=item LU_PREV

Look for the first node matching the specified key (returning C<undef> if not found)
then return C<< $node->prev >>.  This is the same as C<LU_LT> except it ensures the
key existed.
Has alias C<LUPREV> to match Tree::RB.

=back

=cut

*LUEQUAL= *LU_EQ;
*LUGTEQ=  *LU_GE;
*LUGTLT=  *LU_LE;
*LUGREAT= *LU_GT;
*LULESS=  *LU_LT;
*LUPREV=  *LU_PREV;
*LUNEXT=  *LU_NEXT;

1;
