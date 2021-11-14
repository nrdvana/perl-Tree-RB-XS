#!/usr/bin/env perl
use Test2::V0;
use Tree::RB::XS qw( :lookup );
use Time::HiRes 'time';

my $node_cnt= $ENV{TREERBXS_TEST_NODE_COUNT} || 100000;

subtest no_duplicates => sub {
	my $tree= Tree::RB::XS->new(key_type => 'KEY_TYPE_INT');
	$tree->put($_ => $_) for 0, 1, 3;
	
	for (
		[ LU_EQ, 1 => 1 ],
		[ LU_LT, 1 => 0 ],
		[ LU_GT, 1 => 3 ],
		[ LU_LE, 1 => 1 ],
		[ LU_GE, 1 => 1 ],
		[ LU_PREV, 1 => 0 ],
		[ LU_NEXT, 1 => 3 ],
		[ LU_EQ, 2 => undef ],
		[ LU_LT, 2 => 1 ],
		[ LU_GT, 2 => 3 ],
		[ LU_LE, 2 => 1 ],
		[ LU_GE, 2 => 3 ],
		[ LU_PREV, 2 => undef ],
		[ LU_NEXT, 2 => undef ],
		[ LU_EQ, 0 => 0 ],
		[ LU_LT, 0 => undef ],
		[ LU_GT, 0 => 1 ],
		[ LU_LE, 0 => 0 ],
		[ LU_GE, 0 => 0 ],
		[ LU_NEXT, 0 => 1 ],
		[ LU_PREV, 0 => undef ],
	) {
		is( scalar $tree->lookup($_->[1], $_->[0]), $_->[2], "$_->[0] $_->[1]" );
	}
};

done_testing;
