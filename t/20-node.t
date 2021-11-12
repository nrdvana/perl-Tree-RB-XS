#!/usr/bin/env perl
use Test2::V0;
use Tree::RB::XS qw( KEY_TYPE_INT KEY_TYPE_FLOAT KEY_TYPE_STR KEY_TYPE_ANY );
use Time::HiRes 'time';

my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_INT);
$tree->put(1 => 2);
my $node= $tree->min_node;
is( $node->key,    1,     'key'    );
is( $node->value,  2,     'value'  );
is( $node->count,  1,     'count'  );
is( $node->color,  0,     'color'  );
is( $node->parent, undef, 'parent' );
is( $node->left,   undef, 'left'   );
is( $node->right,  undef, 'right'  );
is( $node->next,   undef, 'next'   );
is( $node->prev,   undef, 'prev'   );

is( $tree->max_node,     $node, 'max node same as min' );
is( $tree->nth_node(0),  $node, 'index up from 0' );
is( $tree->nth_node(-1), $node, 'index down from size' );
is( $tree->nth_node(1),  undef, 'no node 1' );

for (1..9) { $tree->put($_ => $_); }
for (2..9) { is( ($node= $node->next)->value, $_, "next -> $_" ) }
is( $node->next, undef, 'end' );

is( $tree->nth_node(5)->value, 6, 'nth(5)' );

$tree= Tree::RB::XS->new(key_type => KEY_TYPE_ANY);
$tree->put(a => 1);
is( $tree->min_node->key, 'a', 'key from type ANY' );

$tree= Tree::RB::XS->new(key_type => KEY_TYPE_FLOAT);
$tree->put(.5 => 1);
is( $tree->min_node->key, 0.5, 'key form type FLOAT' );

done_testing;
