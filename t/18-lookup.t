#!/usr/bin/env perl
use Test2::V0;
use Tree::RB::XS qw( :lookup );
use Time::HiRes 'time';

my $node_cnt= $ENV{TREERBXS_TEST_NODE_COUNT} || 100000;

subtest no_duplicates => sub {
	my $tree= Tree::RB::XS->new(key_type => 'KEY_TYPE_INT');
	$tree->put($_ => $_) for 0, 1, 3;
	
	for (
		[ GET_EQ, 1 => 1 ],
		[ GET_LT, 1 => 0 ],
		[ GET_GT, 1 => 3 ],
		[ GET_LE, 1 => 1 ],
		[ GET_GE, 1 => 1 ],
		[ GET_PREV, 1 => 0 ],
		[ GET_NEXT, 1 => 3 ],
		[ GET_EQ, 2 => undef ],
		[ GET_LT, 2 => 1 ],
		[ GET_GT, 2 => 3 ],
		[ GET_LE, 2 => 1 ],
		[ GET_GE, 2 => 3 ],
		[ GET_PREV, 2 => undef ],
		[ GET_NEXT, 2 => undef ],
		[ GET_EQ, 0 => 0 ],
		[ GET_LT, 0 => undef ],
		[ GET_GT, 0 => 1 ],
		[ GET_LE, 0 => 0 ],
		[ GET_GE, 0 => 0 ],
		[ GET_NEXT, 0 => 1 ],
		[ GET_PREV, 0 => undef ],
	) {
		is( scalar $tree->lookup($_->[1], $_->[0]), $_->[2], "$_->[0] $_->[1]" );
	}
};

done_testing;
