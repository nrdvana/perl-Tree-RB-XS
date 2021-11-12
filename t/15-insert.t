#!/usr/bin/env perl
use Test2::V0;
use Tree::RB::XS qw( KEY_TYPE_INT KEY_TYPE_FLOAT KEY_TYPE_STR KEY_TYPE_ANY );
use Time::HiRes 'time';

my $node_cnt= $ENV{TREERBXS_TEST_NODE_COUNT} || 10000;

note "$_=$ENV{$_}" for grep /perl/i, keys %ENV;

subtest int_tree => sub {
	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_INT);
	is( $tree->insert(1 => 1), 0, 'insert, returns index' );
	is( $tree->size, 1, 'size=1' );
	
	my $t0= time;
	for (2..$node_cnt) {
		$tree->insert($_ => $_);
	}
	my $t1= time;
	is( $tree->size, $node_cnt, "add $node_cnt nodes" );
	note sprintf("Insert rate = %.0f/sec", int($node_cnt/($t1-$t0))) if $t1 > $t0;
	ok(eval { $tree->_assert_structure; 1 }, 'structure OK' )
		or diag $@;
	undef $tree; # test destructor
};

subtest float_tree => sub {
	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_FLOAT);
	is( $tree->insert(1 => 1/10), 0, 'insert, returns index' );
	is( $tree->size, 1, 'size=1' );
	
	my $t0= time;
	for (2..$node_cnt) {
		$tree->insert($_ => $_/10);
	}
	my $t1= time;
	is( $tree->size, $node_cnt, "add $node_cnt nodes" );
	note sprintf("Insert rate = %.0f/sec", int($node_cnt/($t1-$t0))) if $t1 > $t0;
	ok(eval { $tree->_assert_structure; 1 }, 'structure OK' )
		or diag $@;
	undef $tree; # test destructor
};

subtest str_tree => sub {
	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_STR);
	is( $tree->insert(1 => 'x'.1), 0, 'insert, returns index' );
	is( $tree->size, 1, 'size=1' );
	
	my $t0= time;
	for (2..$node_cnt) {
		$tree->insert($_ => "x$_");
	}
	my $t1= time;
	is( $tree->size, $node_cnt, "add $node_cnt nodes" );
	note sprintf("Insert rate = %.0f/sec", int($node_cnt/($t1-$t0))) if $t1 > $t0;
	ok(eval { $tree->_assert_structure; 1 }, 'structure OK' )
		or diag $@;
	undef $tree; # test destructor
};

subtest custom_tree => sub {
	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_ANY, compare_fn => sub { $_[0][0] <=> $_[1][0] });
	is( $tree->insert([1] => 1), 0, 'insert, returns index' );
	is( $tree->size, 1, 'size=1' );
	
	my $t0= time;
	for (2..$node_cnt) {
		$tree->insert([$_], $_);
	}
	my $t1= time;
	is( $tree->size, $node_cnt, "add $node_cnt nodes" );
	note sprintf("Insert rate = %.0f/sec", int($node_cnt/($t1-$t0))) if $t1 > $t0;
	ok(eval { $tree->_assert_structure; 1 }, 'structure OK' )
		or diag $@;
	undef $tree; # test destructor
};

done_testing;
