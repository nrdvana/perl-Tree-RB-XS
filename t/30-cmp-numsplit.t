#!/usr/bin/env perl
use Test2::V0;
use Tree::RB::XS qw/ :key_type :cmp /;
use Time::HiRes 'time';

my @strings= qw(
	10
	20
	20.4.1
	20.4.2
	20.15.1
	foo.20.bar
	foo.7.bar
	2020-1-7_Test
	2020-01-7_Something
	2020-000000000000000000000000000000000000000000000000000000000000001-7_Something
	1test
	2test
	8test
	9test
	10test
	11test
	12test
	999test
	test1test
	test2test
	test10test
	test20test
);

my $i= 0;
my %tiebreak= map +( $_ => ++$i ), @strings;
sub numsplit {
	my @a_parts= split /([0-9]+)/, $a;
	my @b_parts= split /([0-9]+)/, $b;
	my $i= 0;
	while ($i < @a_parts || $i < @b_parts) {
		no warnings 'uninitialized';
		my $cmp= ($i & 1)? ($a_parts[$i] <=> $b_parts[$i])
			: ($a_parts[$i] cmp $b_parts[$i]);
		return $cmp if $cmp;
		++$i;
	}
	# Perl's sort doesn't preserve stable order, but the tree does, so the
	# test will fail without this additional tie-breaker.
	return $tiebreak{$a} <=> $tiebreak{$b};
}


my @perl_sorted= sort { numsplit() } @strings;

subtest scalars => sub {
	my $tree= Tree::RB::XS->new(compare_fn => 'numsplit', key_type => KEY_TYPE_ANY, allow_duplicates => 1);
	is( $tree->compare_fn, CMP_NUMSPLIT );
	is( $tree->key_type, KEY_TYPE_ANY );
	$tree->insert($_ => $_) for @strings;
	my @tree_sorted;
	$i= $tree->iter;
	while (my $n= $i->next) { push @tree_sorted, $n->key; }
	is( \@tree_sorted, \@perl_sorted );
};

subtest bytestrings => sub {
	my $tree= Tree::RB::XS->new(compare_fn => 'numsplit', key_type => KEY_TYPE_BSTR, allow_duplicates => 1);
	is( $tree->compare_fn, CMP_NUMSPLIT );
	is( $tree->key_type, KEY_TYPE_BSTR );
	$tree->insert($_ => $_) for @strings;
	my @tree_sorted;
	$i= $tree->iter;
	while (my $n= $i->next) { push @tree_sorted, $n->key; }
	is( \@tree_sorted, \@perl_sorted );
};

subtest unistrings => sub {
	my $tree= Tree::RB::XS->new(compare_fn => 'numsplit', key_type => KEY_TYPE_USTR, allow_duplicates => 1);
	is( $tree->compare_fn, CMP_NUMSPLIT );
	is( $tree->key_type, KEY_TYPE_USTR );
	$tree->insert($_ => $_) for @strings;
	my @tree_sorted;
	$i= $tree->iter;
	while (my $n= $i->next) { push @tree_sorted, $n->key; }
	is( \@tree_sorted, \@perl_sorted );
};

done_testing;
