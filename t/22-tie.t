#!/usr/bin/env perl
use Test2::V0;
use Tree::RB::XS;
use Time::HiRes 'time';
use Scalar::Util 'weaken';

my %example;
my $t= tie %example, 'Tree::RB::XS';
weaken( my $tref= $t );

ok( !%example ) if $] > 5.025000;
is( ($example{x}= 1), 1, 'store 1' );
is( $t->get('x'), 1, 'stored' );
is( ($example{y}= 2), 2, 'store 2' );
is( $t->get('y'), 2, 'stored' );
ok( %example ) if $] > 5.025000;
is( $example{x}, 1, 'fetch' );
$_= 8 for values %example;
is( delete $example{x}, 8, 'delete' );
$example{x}= 9;
$example{c}= 3;

is( [ keys %example ], [ 'c', 'x', 'y' ], 'keys' );
is( [ values %example ], [ 3, 9, 8 ], 'values' );

undef $t;
untie %example;
is( [ keys %example ], [], 'untied' );
is( $tref, undef, 'tree freed' );

done_testing;
