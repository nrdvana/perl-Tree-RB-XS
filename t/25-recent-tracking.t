#!/usr/bin/env perl
use Test2::V0;
use Tree::RB::XS;
use Time::HiRes 'time';

subtest basic_insertion_order => sub {
   my $t= Tree::RB::XS->new(track_recent => 1);
   is( $t->oldest, undef, 'oldest of empty tree' );
   is( $t->newest, undef, 'newest of empty tree' );
   $t->put(1,1);
   $t->put(2,2);
   $t->put(0,0);
   is( $t->oldest->key, 1, 'oldest' );
   is( $t->newest->key, 0, 'newest' );
   is( $t->recent_count, 3, 'recent_count' );
   is( $t->oldest->newer->key, 2, 'oldest->newer' );
   is( $t->newest->older->key, 2, 'newest->older' );
};

subtest re_insert => sub {
   my $t= Tree::RB::XS->new(track_recent => 1);
   $t->put(1,1);
   $t->put(2,2);
   $t->put(1,1);
   is( $t->oldest->key, 2, 'oldest' );
   is( $t->newest->key, 1, 'newest' );
   is( $t->recent_count, 2, 'recent_count' );
   is( $t->oldest->newer->key, 1, 'oldest->newer' );
   is( $t->newest->older->key, 2, 'newest->older' );
};

subtest delete => sub {
   my $t= Tree::RB::XS->new(track_recent => 1);
   is( $t->oldest, undef, 'oldest' );
   is( $t->newest, undef, 'newest' );
   $t->put(1,1); note( 'put(1,1)' );
   is( $t->oldest->key, 1, 'oldest' );
   is( $t->newest->key, 1, 'newest' );
   ok( $t->delete(1), 'delete(1)' );
   is( $t->recent_count, 0, 'recent_count' );
   is( $t->oldest, undef, 'oldest' );
   is( $t->newest, undef, 'newest' );
   
   $t->put(1,1); note( 'put(1,1)' );
   $t->put(2,2); note( 'put(2,2)' );
   $t->put(3,3); note( 'put(3,3)' );
   $t->put(4,4); note( 'put(4,4)' );
   is( $t->recent_count, 4, 'recent_count = 4' );
   ok( $t->delete(2), 'delete(2)' );
   is( $t->oldest->newer->key, 3, 'oldest->newer' );
   is( $t->newest->older->key, 3, 'newest->older' );
   ok( $t->delete(4), 'delete(4)' );
   is( $t->oldest->newer->key, 3, 'oldest->newer' );
   is( $t->newest->older->key, 1, 'newest->older' );
   ok( $t->delete(1), 'delete(1)' );
   is( $t->oldest->key, 3, 'oldest->newer' );
   is( $t->newest->key, 3, 'newest->older' );
   ok( $t->delete(3), 'delete(3)' );
   is( $t->oldest, undef, 'oldest = null' );
   is( $t->newest, undef, 'newest = null' );
};

subtest iterators => sub {
   my $t= Tree::RB::XS->new(track_recent => 1);
   $t->put(1,1); note 'put(1,1)';
   $t->put(2,2); note 'put(2,2)';
   $t->put(3,3); note 'put(3,3)';
   $t->put(4,4); note 'put(4,4)';
   is( $t->recent_count, 4, 'recent_count = 4' );
   is( [$t->iter_newer->next_keys('*')], [1,2,3,4], 'iter_old_to_new' );
   is( [$t->iter_older->next_keys('*')], [4,3,2,1], 'iter_new_to_old' );
   $t->delete(2); note 'delete(2)';
   is( $t->recent_count, 3, 'recent_count = 3' );
   is( [$t->iter_newer->next_keys('*')], [1,3,4], 'iter_old_to_new' );
   is( [$t->iter_older->next_keys('*')], [4,3,1], 'iter_new_to_old' );
   $t->put(2,2); note 'put(2,2)';
   is( $t->recent_count, 4, 'recent_count = 4' );
   is( [$t->iter_newer->next_keys('*')], [1,3,4,2], 'iter_old_to_new' );
   is( [$t->iter_older->next_keys('*')], [2,4,3,1], 'iter_new_to_old' );
   is( [$t->oldest->iter_newer->next_keys('*')], [1,3,4,2], 'oldest->iter_newer' );
   is( [$t->newest->iter_older->next_keys('*')], [2,4,3,1], 'newest->iter_older' );
   my $iter= $t->iter_newer;
   is( $iter->next_key, 1, 'iter->next_key' );
   is( $iter->next_key, 3, 'iter->next_key' );
   ok( $iter->step(-1), 'iter->step(-1)' );
   is( $iter->next_key, 3, 'iter->next_key' );
   $iter= $t->iter_newer;
   is( $iter->key, 1, 'recent[0] == 1' );
   my $iter2= $t->iter_newer; $iter2->step(1);
   is( $iter2->key, 3, 'recent[1] == 3' );
   my $iter3= $t->iter_older; $iter3->step(1);
   is( $iter3->key, 4, 'recent[-1] == 4' );
   my $iter4= $t->iter_newer; $iter4->step(3);
   is( $iter4->key, 2, 'recent[3] == 1' );
   
   # delete or un-track nodes, and verify iterators bump to correct destination
   $t->get_node(4)->recent_tracked(0);
   is( $iter3->key, 3, 'rev iter bumped backward' );
   $t->delete(3);
   is( $iter3->key, 1, 'rev iter bumped backward' );
   ok( $iter2->key, 2, 'forward iter bumped forward' );
   $t->delete(1);
   is( $iter->key, 2, 'forward iter bumped forward' );
   ok( $iter3->done, 'reverse iter bumped off end' );
   ok( $iter->node == $iter2->node && $iter2->node == $iter4->node, 'iters stacked on final' );
   $t->get_node(4)->mark_newest;
   $t->get_node(2)->recent_tracked(0);
   is( $iter->key, 4, 'iters bumped to new newest node' );
   ok( $iter->node == $iter2->node && $iter2->node == $iter4->node, 'iters stacked on new final' );
   ok( !$iter->step(1), 'step iter1 reaches end' );
   &$iter2;
   ok( $iter2->done, 'iter2 reached end' );
};

done_testing;
