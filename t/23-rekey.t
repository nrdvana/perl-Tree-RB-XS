#!/usr/bin/env perl
use FindBin;
use lib "$FindBin::RealBin/lib";
use Test2WithExplain;
use Tree::RB::XS qw( KEY_TYPE_INT KEY_TYPE_FLOAT );
use Time::HiRes 'time';

subtest error_unless_int_or_float => sub {
	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_INT, kv => [ 1,1 ]);
	ok( eval { $tree->rekey(offset => 1) } );
	$tree= Tree::RB::XS->new(key_type => KEY_TYPE_FLOAT, kv => [ 1,1 ]);
	ok( eval { $tree->rekey(offset => 1.1) } );
	$tree= Tree::RB::XS->new(kv => [ 1,1 ]);
	ok( !eval { $tree->rekey(offset => 1) } );
	$tree= Tree::RB::XS->new(compare_fn => 'numsplit', kv => [ 1,1 ]);
	ok( !eval { $tree->rekey(offset => 1) } );
};

subtest rekey_int_basic => sub {
	my $tree= Tree::RB::XS->new(compare_fn => 'int');
	$tree->rekey(offset => 1);
	is( $tree->size, 0, 'empty tree' );
	$tree->put(1,1);
	$tree->rekey(offset => 2);
	is( [$tree->kv], [ 3,1 ], 'move one key 1 => 3' );
	$tree->put(1,2);
	$tree->rekey(offset => 1);
	is( [$tree->kv], [ 2,2, 4,1 ], 'move two keys' );
	$tree->rekey(offset => 1.5);
	is( [$tree->kv], [ 3,2, 5,1 ], 'truncate NV offset to integer' );
	$tree->rekey(offset => -10);
	is( [$tree->kv], [ -7,2, -5,1 ], 'negative offset' );
};

subtest rekey_int_conflict => sub {
	my $tree= Tree::RB::XS->new(compare_fn => 'int', kv => [ 1,1, 2,2, 5,5, 6,6, 7,7 ]);
	$tree->rekey(offset => -2, min => 5);
	is( [$tree->kv], [ 1,1, 2,2, 3,5, 4,6, 5,7 ], 'remove gap in keys' );
	$tree->rekey(offset => 2, min => 2);
	is( [$tree->kv], [ 1,1, 4,2, 5,5, 6,6, 7,7 ], 'insert gap in keys' );
	$tree->rekey(offset => -3, min => 2);
	is( [$tree->kv], [ 1,2, 2,5, 3,6, 4,7 ], 'clobber key 1' );
};

done_testing;
