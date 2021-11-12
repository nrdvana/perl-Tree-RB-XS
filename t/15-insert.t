#!/usr/bin/env perl
use Test2::V0;
use Tree::RB::XS qw( KEY_TYPE_INT KEY_TYPE_FLOAT KEY_TYPE_STR );

subtest int_tree => sub {
	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_INT)->allow_duplicates(1);
	is( $tree->put(1 => 1), $tree, 'put, returns self' );
	is( $tree->count, 1, 'count=1' );
	
	for (1..1000) {
		$tree->put(int(rand) => $_);
	}
	is( $tree->count, 1001, 'add 100 nodes' );
	ok( $tree->_check_structure, 'structure OK' );
	undef $tree; # test destructor
};

#subtest float_tree => sub {
#	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_FLOAT);
#	like( $tree, $looks_like_tree, 'is a tree obj' );
#	is( $tree->key_type, KEY_TYPE_FLOAT, 'key_type' );
#	$SIG{__WARN__}= sub { die; }; # make sure exceptions in DESTROY show as failures
#	undef $tree; # test destructor
#};
#
#subtest str_tree => sub {
#	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_STR);
#	like( $tree, $looks_like_tree, 'is a tree obj' );
#	is( $tree->key_type, KEY_TYPE_STR, 'key_type' );
#	$SIG{__WARN__}= sub { die; }; # make sure exceptions in DESTROY show as failures
#	undef $tree; # test destructor
#};

done_testing;
