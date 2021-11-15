#!/usr/bin/env perl
use Test2::V0;
use Tree::RB::XS;
use Time::HiRes 'time';

my $tree= Tree::RB::XS->new(key_type => 'int');
$tree->put($_ => $_) for 0, 1, 2, 4;
is( $tree->iter->next->value, 0 );
is( $tree->iter(2)->next->value, 2 );
is( $tree->iter(3)->next->value, 4 );
is( $tree->rev_iter(1)->next->value, 1 );
is( $tree->rev_iter(3)->next->value, 2 );

$tree->allow_duplicates(1);
$tree->insert(2, '2a');
$tree->insert(2, '2b');
is( $tree->iter(2)->next->value, 2 );
is( $tree->rev_iter(2)->next->value, '2b' );

done_testing;
