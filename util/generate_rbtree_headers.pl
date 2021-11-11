#! /usr/bin/env perl
use FindBin;
use lib $FindBin::Bin;
use strict;
use warnings;
use RBGen;

RBGen->new(namespace => 'rbtree_')
    ->write_api("./rbtree.h")
    ->write_impl("./rbtree.c")
    ->write_wrapper(
		'TreeRBXS_tree.h',
		obj_t => 'struct TreeRBXS_item',
		tree_t => 'struct TreeRBXS_tree',
		node_field => 'rbnode',  # struct SomeType { RBTreeNode_t NodeFieldName; }
		cmp => 'TreeRBXS_compare_items'     # int CompareFunc(SomeType *a, SomeType *b);
	);

#ident_rb.h: $(realsrcdir)/RBGen.pm
#	perl -I$(realsrcdir) -MRBGen -e 'RBGen->new(namespace => "userp_rb")->write_wrapper("ident_rb.h", obj_t => "userp_ident_t", node => "name_tree_node", key_t => "const char *", key => "name", tree_t => "userp_ident_by_name_t", cmp => "compare_charstar")'
