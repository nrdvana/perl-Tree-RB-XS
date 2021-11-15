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
our @_lookup_modes= qw( GET_EQ GET_EQ_LAST GET_GT GET_LT GET_GE GET_LE GET_LE_LAST GET_NEXT GET_PREV
                        LUEQUAL LUGTEQ LULTEQ LUGREAT LULESS LUNEXT LUPREV );
our @EXPORT_OK= (@_key_types, @_cmp_enum, @_lookup_modes);
our %EXPORT_TAGS= (
	key_type => \@_key_types,
	cmp      => \@_cmp_enum,
	lookup   => \@_lookup_modes,
);

=head1 SYNOPSIS

B<NOTICE:> This module is very new and you should give it some thorough testing before
trusting it with production data.

  my $tree= Tree::RB::XS->new;
  $tree->put($_ => $_) for 'a'..'z';
  say $tree->get('a');
  $tree->delete('a');
  say $tree->get('a', GET_GT); # finds 'b'
  $tree->delete('a','z');
  $tree->delete($tree->min, $tree->max);
  
  # optimize for integer comparisons
  $tree= Tree::RB::XS->new(key_type => KEY_TYPE_INT);
  $tree->put(1 => "x");

  # optimize for floating-point comparisons
  $tree= Tree::RB::XS->new(key_type => 'float', allow_duplicates => 1);
  $tree->put(rand() => 1);
  $tree->delete(0, $tree->get_node_lt(.5));

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

This module is a wrapper for a Red/Black Tree implemented in C.  It's primary features over
other search trees on CPAN are optimized comparisons of keys (speed), C<< O(log N) >>
node-by-index lookup (which allows the tree to act as an array), and the option to
allow duplicate keys while preserving insertion order.

The API is close but not identical to L<Tree::RB>.

=over

=item *

The C<get> method in this module is not affected by array context, unless you
request L</compat_list_get>.

=item *

C<resort> is not implemented (would be lots of effort, and unlikely to be needed)

=item *

tie-hash interface and hseek are not implemented.  (not hard, but does anyone need it?)

=item *

Tree structure is not mutable via the attributes of Node, nor can nodes be created
independent from a tree.

=item *

Many functions have official names changed, but aliases are provided for compatibility.

=back

=head1 CONSTRUCTOR

=head2 new

  my $tree= Tree::RB::XS->new( %OPTIONS );
                     ...->new( sub($x,$y) { $x cmp $y });

Options:

=over

=item L</key_type>

Choose an optimized storage for keys.  The default is L</KEY_TYPE_ANY> which stores
whole perl scalars.  All the other types are faster, but perl scalars give the fewest
surprises.

=item L</compare_fn>

Choose a custom key-compare function.  The default depends on C<key_type>.
If this is a perl coderef, the C<key_type> is forced to be L</KEY_TYPE_ANY>.
Avoid using a coderef if possible.

=item L</allow_duplicates>

Whether to allow two nodes with the same key.  Defaults to false.

=item L</compat_list_get>

Whether to enable full compatibility with L<Tree::RB>'s list-context behavior for L</get>.
Defaults to false.

=back

=cut

sub new {
	my $class= shift;
	my %options= @_ == 1 && ref $_[0] eq 'CODE'? ( compare_fn => $_[0] ) : @_;
	my $self= bless \%options, $class;
	$self->_init_tree(delete $self->{key_type}, delete $self->{compare_fn});
	$self->allow_duplicates(1) if delete $self->{allow_duplicates};
	$self->compat_list_get(1) if delete $self->{compat_list_get};
	$self;
}

=head1 ATTRIBUTES

=head2 key_type

The key-storage strategy used by the tree.  Read-only; pass as an option to
the constructor.

This is one of the following values: L</KEY_TYPE_ANY>, L</KEY_TYPE_INT>,
L</KEY_TYPE_FLOAT>, L</KEY_TYPE_BSTR>, or L</KEY_TYPE_USTR>.
See the description in EXPORTS for full details on each.  If importing constants
is annoying, you can specify these simply as C<"any">, C<"int">, C<"float">,
C<"bstr">, and C<"ustr">.

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

If set to a perl coderef, it should take two parameters and return an integer
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

=head2 compat_list_get

Boolean, read/write.  Controls whether L</get> returns multiple values in list context.
I wanted to match the API of C<Tree::RB>, but I can't bring myself to make an innocent-named
method like 'get' change its behavior in list context.  So, by deault, this attribute is
false and C<get> always returns one value.  But if you set this to true, C<get> changes in
list context to also return the Node, like is done in L<Tree::RB/lookup>.

=head2 size

Returns the number of elements in the tree.

=head2 root_node

Get the root node of the tree, or C<undef> if the tree is empty.

Alias: C<root>

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

*root= *root_node;
*min= *min_node;
*max= *max_node;
*nth= *nth_node;

=head1 METHODS

=head2 get

  my $val= $tree->get($key);
                ->get($key, $mode);

Fetch a value from the tree, by its key.  Unlike L<Tree::RB/get>, this always
returns a single value, regardless of list context.  But, you can set
L<compat_list_get> to make C<get> an alias for C<lookup>.

Mode can be used to indicate something other than an exact match:
L</GET_EQ>, L</GET_EQ_LAST>, L</GET_LE>, L</GET_LE_LAST>, L</GET_LT>, L</GET_GE>, L</GET_GT>.

=head2 get_node

Same as L</get>, but returns the node instead of the value.  In trees with
duplicate keys, this always returns the first node.  (nodes with identical keys
are preserved in the order they were added)

Aliases with built-in mode constants:

=over 20

=item get_node_last

=item get_node_le

=item get_node_le_last

=item get_node_lt

=item get_node_ge

=item get_node_gt

=back

=head2 get_all

  my @values= $tree->get_all($key);

In trees with duplicate keys, this method is useful to return the values of all
nodes that match the key.  This can be more efficient than stepping node-to-node
for small numbers of duplicates, but beware that large numbers of duplicate could
have an adverse affect on Perl's stack.

=head2 lookup

Provided for compatibility with Tree::RB.  Same as L</get> in scalar context, but
if called in list context it returns both the value and the node from L</get_node>.
You can also use Tree::RB's lookup-mode constants of "LUEQUAL", etc.

=head2 put

  my $old_val= $tree->put($key, $new_val);

Associate the key with a new value.  If the key previously existed, this returns
the old value, and updates the tree to reference the new value.  If the tree
allows duplicate keys, this will replace all nodes having this key (but only return
one of them).

=head2 insert

Insert a new node into the tree, and return the index at which it was inserted.
If L</allow_duplicates> is not enabled, and the node already existed, this returns -1
and does not change the tree.  If C<allow_duplicates> is enabled, this adds the new
node after all nodes of the same key, preserving the insertion order.

=head2 delete

  my $count= $tree->delete($key);
                  ->delete($key1, $key2);
                  ->delete($node1, $node2);
                  ->delete($start, $tree->get($limit, GET_LT));

Delete any node with a key identical to C<$key>, and return the number of nodes
removed.  If you supply two keys (or two nodes) this will delete those nodes and
all nodes inbetween; C<$key1> is searched with mode C<GET_GE> and C<$key2> is
searched with mode C<GET_LE>, so the keys themselves do not need to be found in
the tree.
The keys (or nodes) most be given in ascending order, else no nodes are deleted.

If you want to delete a range *exclusive* of one or both ends of the range, just
use the C</get> method with the desired mode to look up each end of the nodes that
you do want removed.

=head2 iter

  my $iter= $tree->iter;
                 ->iter($from_key);
  while (my $node= $iter->()) { ... }
  while (my $node= $iter->next) { ... }

Return an iterator object that traverses the tree.  The iterator is a blesed coderef, so you
can either call it as a fuction or call the C<< ->next >> method.  If the C<$from_key> is
provided, this starts from C<< $tree->get($key, GET_GE) >>.

=head2 rev_iter

Like C<iter>, but the C<< ->next >> method walks backward to smaller key values, and if the
initial value is provided and duplicate keys are enabled, this starts on the right-most match
of the key instead of the left-most match.

=cut

sub iter {
	my $self= shift;
	my $node= @_? $self->get_node($_[0], GET_GE()) : $self->min;
	bless sub { my $x= $node; $node= $node->next if $node; $x }, 'Tree::RB::XS::Iter';
}

sub rev_iter {
	my $self= shift;
	my $node= @_? $self->get_node($_[0], GET_LE_LAST()) : $self->max;
	bless sub { my $x= $node; $node= $node->prev if $node; $x }, 'Tree::RB::XS::Iter';
}

sub Tree::RB::XS::Iter::next { shift->() }

=head1 NODE OBJECTS

The nodes returned by the methods above have the following attributes:

=over 10

=item key

The sort key.  Read-only, but if you supplied a reference and you modify what it
points to, you will break the sorting of the tree.

=item value

The data associated with the node.  Read/Write.

=item prev

The previous node in the sequence of keys.  Alias C<predecessor> for C<Tree::RB::Node> compat.

=item next

The next node in the sequence of keys.  Alias C<successor> for C<Tree::RB::Node> compat.

=item tree

The tree this node belongs to.  This becomes C<undef> if the tree is freed or if the node
is pruned from the tree.

=item left

The left sub-tree.

=item left_leaf

The left-most leaf of the sub-tree.  Alias C<min> for C<Tree::RB::Node> compat.

=item right

The right sub-tree.

=item right_leaf

The right-most child of the sub-tree.  Alias C<max> for C<Tree::RB::Node> compat.

=item parent

The parent node, if any.

=item color

0 = black, 1 = red.

=item count

The number of items in the tree rooted at this node (inclusive)

=back

=cut

*Tree::RB::XS::Node::min=         *Tree::RB::XS::Node::left_leaf;
*Tree::RB::XS::Node::max=         *Tree::RB::XS::Node::right_leaf;
*Tree::RB::XS::Node::successor=   *Tree::RB::XS::Node::next;
*Tree::RB::XS::Node::predecessor= *Tree::RB::XS::Node::prev;

=pod

And the following methods:

=over 10

=item prune

Remove this single node from the tree.  The node will still have its key and value,
but all attributes linking to other nodes will become C<undef>.

=item strip

Remove all children of this node, optionally calling a callback for each.
For compat with L<Tree::RB::Node/strip>.

=item as_lol

Return sub-tree as list-of-lists. (array of arrays rather?)
For compat with L<Tree::RB::Node/as_lol>.

=back

=cut

sub Tree::RB::XS::Node::strip {
	my ($self, $cb)= @_;
	my ($at, $next, $last)= (undef, $self->left_leaf || $self, $self->right_leaf || $self);
	do {
		$at= $next;
		$next= $next->next;
		if ($at != $self) {
			$at->prune;
			$cb->($at) if $cb;
		}
	} while ($at != $last);
}

sub Tree::RB::XS::Node::as_lol {
	my $self= $_[1] || $_[0];
	[
		$self->left? $self->left->as_lol : '*',
		$self->right? $self->right->as_lol : '*',
		($self->color? 'R':'B').':'.($self->key||'')
	]
}

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

=head2 Comparison Functions

Export all with ':cmp'

=over

=item CMP_PERL

Use Perl's C<cmp> function.  This forces the keys of the nodes to be stored as
Perl Scalars.

=item CMP_INT

Compare keys directly as C integers.  This is the fastest option.

=item CMP_FLOAT

Compare the keys directly as C 'double' values.

=item CMP_UTF8

Compare the keys as UTF8 byte strings, using Perl's internal C<bytes_cmp_utf8> function.

=item CMP_MEMCMP

Compare the keys using C's C<memcmp> function.

=back

=head2 Lookup Mode

Export all with ':get'

=over

=item GET_EQ

This specifies a node with a key equal to the search key.  If duplicate keys are enabled,
this specifies the left-most match (least recently added).
Has alias C<LUEQUAL> to match Tree::RB.

=item GET_EQ_LAST

Same as C<GET_EQ>, but if duplicate keys are enabled, this specifies the right-most match
(most recently inserted).

=item GET_GE

This specifies the same node of C<GET_EQ>, unless there are no matches, then it falls back
to the left-most node with a key greater than the search key.
Has alias C<LUGTEQ> to match Tree:RB.

=item GET_LE

This specifies the same node of C<GET_EQ>, unless there are no matches, then it falls back
to the right-most node with a key less than the search key.
Has alias C<LULTEQ> to match Tree::RB.

=item GET_LE_LAST

This specifies the same node of C<GET_EQ_LAST>, unless there are no matches, then it falls
back to the right-most node with a key less than the search key.

=item GET_GT

Return the first node greater than the key,
or C<undef> if the key is greater than any node.
Has alias C<LUGREAT> to match Tree::RB.

=item GET_LT

Return the right-most node less than the key,
or C<undef> if the key is less than any node.
Has alias C<LULESS> to match Tree::RB.

=item GET_NEXT

Look for the last node matching the specified key (returning C<undef> if not found)
then return C<< $node->next >>.  This is the same as C<GET_GT> except it ensures the
key existed.
Has alias C<LUNEXT> to match Tree::RB.

=item GET_PREV

Look for the first node matching the specified key (returning C<undef> if not found)
then return C<< $node->prev >>.  This is the same as C<GET_LT> except it ensures the
key existed.
Has alias C<LUPREV> to match Tree::RB.

=back

=cut

*LUEQUAL= *GET_EQ;
*LUGTEQ=  *GET_GE;
*LUGTLT=  *GET_LE;
*LUGREAT= *GET_GT;
*LULESS=  *GET_LT;
*LUPREV=  *GET_PREV;
*LUNEXT=  *GET_NEXT;

1;
