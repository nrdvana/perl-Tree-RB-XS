#!/usr/bin/env perl
use Test2::V0;
use Tree::RB::XS qw( :key_type :cmp );
use Scalar::Util 'weaken';

# check dualvar behavior
is( KEY_TYPE_ANY, 'KEY_TYPE_ANY', "enums stringify as text" );
ok( KEY_TYPE_ANY == 1, "enums are still ints" );

my $looks_like_tree= object sub {
	prop isa => 'Tree::RB::XS';
	call key_type => T();
	call allow_duplicates => 0;
	call size => 0;
};

subtest default_tree => sub {
	my $tree= Tree::RB::XS->new;
	weaken(my $tref= $tree);
	like( $tree, $looks_like_tree, 'is a tree obj' );
	is( $tree->key_type, KEY_TYPE_ANY, 'key_type' );
	is( $tree->compare_fn, CMP_PERL, 'compare_fn' );
	undef $tree; # test destructor
	is( $tref, undef, 'tree freed' );
};

subtest int_tree => sub {
	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_INT);
	weaken(my $tref= $tree);
	like( $tree, $looks_like_tree, 'is a tree obj' );
	is( $tree->key_type, KEY_TYPE_INT, 'key_type' );
	is( $tree->compare_fn, CMP_INT, 'compare_fn' );
	undef $tree; # test destructor
	is( $tref, undef, 'tree freed' );
};

subtest float_tree => sub {
	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_FLOAT);
	weaken(my $tref= $tree);
	like( $tree, $looks_like_tree, 'is a tree obj' );
	is( $tree->key_type, KEY_TYPE_FLOAT, 'key_type' );
	is( $tree->compare_fn, CMP_FLOAT, 'compare_fn' );
	undef $tree; # test destructor
	is( $tref, undef, 'tree freed' );
};

$] >= 5.01400 && subtest ustr_tree => sub {
	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_USTR);
	weaken(my $tref= $tree);
	like( $tree, $looks_like_tree, 'is a tree obj' );
	is( $tree->key_type, KEY_TYPE_USTR, 'key_type' );
	is( $tree->compare_fn, CMP_UTF8, 'compare_fn' );
	undef $tree; # test destructor
	is( $tref, undef, 'tree freed' );
};

subtest bstr_tree => sub {
	my $tree= Tree::RB::XS->new(key_type => KEY_TYPE_BSTR);
	weaken(my $tref= $tree);
	like( $tree, $looks_like_tree, 'is a tree obj' );
	is( $tree->key_type, KEY_TYPE_BSTR, 'key_type' );
	is( $tree->compare_fn, CMP_MEMCMP, 'compare_fn' );
	undef $tree; # test destructor
	is( $tref, undef, 'tree freed' );
};

subtest custom_tree => sub {
	my $cmp= sub { $_[0] <=> $_[1] };
	my $tree= Tree::RB::XS->new(compare_fn => $cmp);
	weaken(my $tref= $tree);
	like( $tree, $looks_like_tree, 'is a tree obj' );
	is( $tree->key_type, KEY_TYPE_ANY, 'key_type' );
	is( $tree->compare_fn, $cmp, 'compare_fn' );
	undef $tree; # test destructor
	is( $tref, undef, 'tree freed' );
};

subtest type_by_name => sub {
	my $tree= Tree::RB::XS->new(key_type => 'KEY_TYPE_BSTR');
	is( $tree->key_type, KEY_TYPE_BSTR, 'key_type' );
};	

done_testing;
