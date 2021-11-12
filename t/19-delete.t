#!/usr/bin/env perl
use Test2::V0;
use Tree::RB::XS qw( KEY_TYPE_INT KEY_TYPE_FLOAT KEY_TYPE_STR KEY_TYPE_ANY );
use Time::HiRes 'time';

# Perform a sequence of edits on both a hash and the tree, then
# assert that they contain the same list.

my @edits= (
	{ add => [qw( a b c d e f )] },
	{ del => [qw( a x )] },
	{ add => [qw( x y z )] },
	{ del => [qw( d y f )] },
);

my %hash;
my $tree= Tree::RB::XS->new;

for (0 .. $#edits) {
	my $add= $edits[$_]{add} || [];
	my $del= $edits[$_]{del} || [];
	for (@$add) {
		$tree->put($_ => $_);
		$hash{$_}= $_;
	}
	for (@$del) {
		$tree->delete($_);
		delete $hash{$_};
	}
	my @keys;
	for (my $node= $tree->min; $node; $node= $node->next) {
		push @keys, $node->key;
	}
	is( \@keys, [ sort keys %hash ], "keys after edit $_" );
}
undef $tree;

done_testing;
