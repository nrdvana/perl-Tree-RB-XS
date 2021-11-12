#!/usr/bin/env perl
use Test2::V0;
use Tree::RB::XS qw( KEY_TYPE_INT KEY_TYPE_FLOAT KEY_TYPE_STR );

my $looks_like_tree= object sub {
	prop isa => 'Tree::RB::XS';
	call key_type => T();
	call allow_duplicates => 0;
	call size => 0;
};

subtest default_tree => sub {
	my $tree= Tree::RB::XS->new;
	like( $tree, $looks_like_tree, 'is a tree obj' );
	is( $tree->key_type, KEY_TYPE_STR, 'key_type' );
	$SIG{__WARN__}= sub { die; }; # make sure exceptions in DESTROY show as failures
	undef $tree; # test destructor
};

subtest int_tree => sub {
	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_INT);
	like( $tree, $looks_like_tree, 'is a tree obj' );
	is( $tree->key_type, KEY_TYPE_INT, 'key_type' );
	$SIG{__WARN__}= sub { die; }; # make sure exceptions in DESTROY show as failures
	undef $tree; # test destructor
};

subtest float_tree => sub {
	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_FLOAT);
	like( $tree, $looks_like_tree, 'is a tree obj' );
	is( $tree->key_type, KEY_TYPE_FLOAT, 'key_type' );
	$SIG{__WARN__}= sub { die; }; # make sure exceptions in DESTROY show as failures
	undef $tree; # test destructor
};

subtest str_tree => sub {
	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_STR);
	like( $tree, $looks_like_tree, 'is a tree obj' );
	is( $tree->key_type, KEY_TYPE_STR, 'key_type' );
	$SIG{__WARN__}= sub { die; }; # make sure exceptions in DESTROY show as failures
	undef $tree; # test destructor
};

done_testing;
