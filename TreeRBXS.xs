#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#define AUTOCREATE 1
#define OR_DIE 2
#define KEY_TYPE_ANY 1
#define KEY_TYPE_INT 2
#define KEY_TYPE_FLOAT 3
#define KEY_TYPE_STR 4
#define KEY_TYPE_MAX 4

/* The core Red/Black algorithm which operates on rbtree_node_t */
#include "rbtree.h"

struct TreeRBXS;
struct TreeRBXS_item;

typedef int TreeRBXS_cmp_fn(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b);

struct TreeRBXS {
	SV *owner;
	int key_type;
	bool allow_duplicates;
	TreeRBXS_cmp_fn *compare;
	SV *compare_callback;
	rbtree_node_t root_sentinel;
	rbtree_node_t leaf_sentinel;
	struct TreeRBXS_item *tmp_item;
	HV *iterators;
};

#define OFS_TreeRBXS_item_FIELD_rbnode ( ((char*) &(((struct TreeRBXS_item *)(void*)10000)->rbnode)) - ((char*)10000) )
#define GET_TreeRBXS_item_FROM_rbnode(node) ((struct TreeRBXS_item*) (((char*)node) - OFS_TreeRBXS_item_FIELD_rbnode))

#define TREERBXS_ITEM_SKEY 1
struct TreeRBXS_item {
	SV *owner;
	rbtree_node_t rbnode;
	union itemkey_u {
		IV ikey;
		NV nkey;
		SV *skey;
	} keyunion;
	SV *value;
	int flags;
};

static void TreeRBXS_assert_structure(struct TreeRBXS *tree) {
	int err;
	if (!tree) croak("tree is NULL");
	if (!tree->owner) croak("no owner");
	if (tree->key_type < 0 || tree->key_type > KEY_TYPE_MAX) croak("bad key_type");
	if (!tree->compare) croak("no compare function");
	if (err= rbtree_check_structure(&tree->root_sentinel, (int(*)(void*,void*,void*)) tree->compare, tree, -OFS_TreeRBXS_item_FIELD_rbnode))
		croak("tree structure damaged: %d", err);
	if (tree->tmp_item) {
		if (rbtree_node_is_in_tree(&tree->tmp_item->rbnode))
			croak("temp node added to tree");
	}
	//warn("Tree is healthy");
}

/* For insert/put, there needs to be a node created before it can be
 * inserted.  But if the insert fails, the item needs cleaned up.
 * By using a temp item attached to the tree, it can be re-used if
 * the insert fails and save a little overhead and messy exception handling.
 */
static void TreeRBXS_init_tmp_item(struct TreeRBXS *tree, SV *key, SV *value) {
	/* Prepare a new item with the key initialized */
	struct TreeRBXS_item *item= tree->tmp_item;
	if (item) {
		memset(&item->rbnode, 0, sizeof(item->rbnode));
	} else {
		Newxz(item, 1, struct TreeRBXS_item);
		tree->tmp_item= item;
	}
	/* key_type can never change, so it is safe to assume that previous init
	 * of the item is the same as what would occur now.
	 */
	switch (tree->key_type) {
	case KEY_TYPE_STR:
	case KEY_TYPE_ANY:   if (item->keyunion.skey)
	                         sv_setsv(item->keyunion.skey, key);
	                     else
	                         item->keyunion.skey= newSVsv(key);
	                     item->flags |= TREERBXS_ITEM_SKEY;
	                     break;
	case KEY_TYPE_INT:   item->keyunion.ikey= SvIV(key); break;
	case KEY_TYPE_FLOAT: item->keyunion.nkey= SvNV(key); break;
	default:             croak("BUG: unhandled key_type");
	}
	if (item->value)
		sv_setsv(item->value, value);
	else
		item->value= newSVsv(value);
}

static void TreeRBXS_item_free(struct TreeRBXS_item *item) {
	if (item->flags & TREERBXS_ITEM_SKEY)
		SvREFCNT_dec(item->keyunion.skey);
	if (item->value)
		SvREFCNT_dec(item->value);
	Safefree(item);
}

static void TreeRBXS_item_detach_owner(struct TreeRBXS_item* item) {
	item->owner= NULL;
	/* The tree is the other 'owner' of the node.  If the item is not in the tree,
	   then this was the last reference, and it needs freed. */
	if (!rbtree_node_is_in_tree(&item->rbnode))
		TreeRBXS_item_free(item);
}

static void TreeRBXS_item_detach_tree(struct TreeRBXS_item* item, struct TreeRBXS *tree) {
	//warn("detach tree %p %p key %d", item, tree, (int) item->keyunion.ikey);
	/* The item could be owned by a tree or by a Node/Iterator, or both.
	   If the tree releases the reference, the Node/Iterator will be the owner. */
	if (!item->owner)
		TreeRBXS_item_free(item);
	/* Else the tree was the only owner, and the node needs freed */
}

static void TreeRBXS_destroy(struct TreeRBXS *tree) {
	//warn("TreeRBXS_destroy");
	rbtree_clear(&tree->root_sentinel, (void (*)(void *, void *)) &TreeRBXS_item_detach_tree, -OFS_TreeRBXS_item_FIELD_rbnode, tree);
	if (tree->tmp_item) {
		TreeRBXS_item_free(tree->tmp_item);
		tree->tmp_item= NULL;
	}
	if (tree->compare_callback)
		SvREFCNT_dec(tree->compare_callback);
}

static int TreeRBXS_cmp_int(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	//warn("  int compare %p (%d) <=> %p (%d)", a, (int)a->keyunion.ikey, b, (int)b->keyunion.ikey);
	IV diff= a->keyunion.ikey - b->keyunion.ikey;
	return diff < 0? -1 : diff > 0? 1 : 0; /* shrink from IV to int might lose upper bits */
}
static int TreeRBXS_cmp_str(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	return sv_cmp(a->keyunion.skey, b->keyunion.skey);
}
static int TreeRBXS_cmp_float(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	NV diff= a->keyunion.nkey - b->keyunion.nkey;
	return diff < 0? -1 : diff > 0? 1 : 0;
}
static int TreeRBXS_cmp_perl(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	int ret;
    dSP;
	//warn("compare(%s:%s, %s:%s)",
	//	SvPV_nolen(a->flags&TREERBXS_ITEM_SKEY? a->keyunion.skey : sv_2mortal(newSViv(a->keyunion.ikey))),
	//	SvPV_nolen(a->value),
	//	SvPV_nolen(b->flags&TREERBXS_ITEM_SKEY? b->keyunion.skey : sv_2mortal(newSViv(b->keyunion.ikey))),
	//	SvPV_nolen(b->value)
	//);
    ENTER;
	// There are a max of $tree_depth comparisons to do during an insert or search,
	// so should be safe to not free temporaries for a little bit.
    PUSHMARK(SP);
    EXTEND(SP, 2);
    PUSHs(a->keyunion.skey);
    PUSHs(b->keyunion.skey);
    PUTBACK;
    if (call_sv(tree->compare_callback, G_SCALAR) != 1)
        croak("stack assertion failed");
    SPAGAIN;
    ret= POPi;
    PUTBACK;
	// FREETMPS;
    LEAVE;
    return ret;
}

/*------------------------------------------------------------------------------------
 * This defines the "Magic" that perl attaches to a scalar.
 */
static int TreeRBXS_magic_free(pTHX_ SV* sv, MAGIC* mg) {
    if (mg->mg_ptr) {
        TreeRBXS_destroy((struct TreeRBXS*) mg->mg_ptr);
		Safefree(mg->mg_ptr);
		mg->mg_ptr= NULL;
	}
    return 0; // ignored anyway
}
#ifdef USE_ITHREADS
static int TreeRBXS_magic_dup(pTHX_ MAGIC *mg, CLONE_PARAMS *param) {
    croak("This object cannot be shared between threads");
    return 0;
};
#else
#define TreeRBXS_magic_dup 0
#endif

static MGVTBL TreeRBXS_magic_vt= {
	0, /* get */
	0, /* write */
	0, /* length */
	0, /* clear */
	TreeRBXS_magic_free,
	0, /* copy */
	TreeRBXS_magic_dup
#ifdef MGf_LOCAL
	,0
#endif
};

static int TreeRBXS_item_magic_free(pTHX_ SV* sv, MAGIC* mg) {
	if (mg->mg_ptr) {
		TreeRBXS_item_detach_owner((struct TreeRBXS_item*) mg->mg_ptr);
		mg->mg_ptr= NULL;
	}
	return 0;
}

static MGVTBL TreeRBXS_item_magic_vt= {
	0, /* get */
	0, /* write */
	0, /* length */
	0, /* clear */
	TreeRBXS_item_magic_free,
	0, /* copy */
	TreeRBXS_magic_dup
#ifdef MGf_LOCAL
	,0
#endif
};

/* Get TreeRBXS struct attached to a Perl SV Ref.
 * Use AUTOCREATE to attach magic if it wasn't present.
 * Use OR_DIE for a built-in croak() if the return value would be NULL.
 */
static struct TreeRBXS* TreeRBXS_get_magic_tree(SV *obj, int flags) {
	SV *sv;
	MAGIC* magic;
    struct TreeRBXS *tree;
	if (!sv_isobject(obj)) {
		if (flags & OR_DIE)
			croak("Not an object");
		return NULL;
	}
	sv= SvRV(obj);
	if (SvMAGICAL(sv)) {
        /* Iterate magic attached to this scalar, looking for one with our vtable */
        for (magic= SvMAGIC(sv); magic; magic = magic->mg_moremagic)
            if (magic->mg_type == PERL_MAGIC_ext && magic->mg_virtual == &TreeRBXS_magic_vt)
                /* If found, the mg_ptr points to the fields structure. */
                return (struct TreeRBXS*) magic->mg_ptr;
    }
    if (flags & AUTOCREATE) {
        Newxz(tree, 1, struct TreeRBXS);
        magic= sv_magicext(sv, NULL, PERL_MAGIC_ext, &TreeRBXS_magic_vt, (const char*) tree, 0);
#ifdef USE_ITHREADS
        magic->mg_flags |= MGf_DUP;
#endif
		rbtree_init_tree(&tree->root_sentinel, &tree->leaf_sentinel);
        return tree;
    }
    else if (flags & OR_DIE)
        croak("Object lacks 'struct TreeRBXS' magic");
	return NULL;
}

static struct TreeRBXS_item* TreeRBXS_get_magic_item(SV *obj, int flags) {
	SV *sv;
	MAGIC* magic;
    struct TreeRBXS_item *item;
	if (!sv_isobject(obj)) {
		if (flags & OR_DIE)
			croak("Not an object");
		return NULL;
	}
	sv= SvRV(obj);
	if (SvMAGICAL(sv)) {
        /* Iterate magic attached to this scalar, looking for one with our vtable */
        for (magic= SvMAGIC(sv); magic; magic = magic->mg_moremagic)
            if (magic->mg_type == PERL_MAGIC_ext && magic->mg_virtual == &TreeRBXS_item_magic_vt)
                /* If found, the mg_ptr points to the fields structure. */
                return (struct TreeRBXS_item*) magic->mg_ptr;
    }
    if (flags & OR_DIE)
        croak("Object lacks 'struct TreeRBXS_item' magic");
	return NULL;
}

static void TreeRBXS_set_magic_item(SV *obj, struct TreeRBXS_item *item) {
	SV *sv, *oldowner;
	MAGIC* magic;
	struct TreeRBXS_item *olditem;

	if (!sv_isobject(obj))
		croak("Not an object");
	sv= SvRV(obj);

	if (item->owner) {
		/* does the object already own this item? */
		if (item->owner == sv)
			return;
		/* detach item from old owner */
        for (magic= SvMAGIC(item->owner); magic; magic = magic->mg_moremagic)
            if (magic->mg_type == PERL_MAGIC_ext && magic->mg_virtual == &TreeRBXS_item_magic_vt) {
				magic->mg_ptr= NULL;
				break;
			}
	}

	item->owner= obj;

	/* If the object already owns one item, need to release that reference, possibly freeing the item */
	if (SvMAGICAL(sv)) {
        /* Iterate magic attached to this scalar, looking for one with our vtable */
        for (magic= SvMAGIC(sv); magic; magic = magic->mg_moremagic)
            if (magic->mg_type == PERL_MAGIC_ext && magic->mg_virtual == &TreeRBXS_item_magic_vt) {
                /* If found, the mg_ptr points to the fields structure. */
                if (magic->mg_ptr)
					TreeRBXS_item_detach_owner((struct TreeRBXS_item*) magic->mg_ptr);
				/* replace it with a new pointer */
				magic->mg_ptr= (char*) item;
				return;
			}
	}
	magic= sv_magicext(sv, NULL, PERL_MAGIC_ext, &TreeRBXS_item_magic_vt, (char*) item, 0);
#ifdef USE_ITHREADS
	magic->mg_flags |= MGf_DUP;
#endif
}

MODULE = Tree::RB::XS              PACKAGE = Tree::RB::XS

void
_init_tree(obj, key_type, compare_fn= NULL)
	SV *obj
	int key_type
	SV *compare_fn
	INIT:
		struct TreeRBXS *tree;
	PPCODE:
		if (!sv_isobject(obj))
			croak("_init_tree called on non-object");
		if (key_type <= 0 || key_type > KEY_TYPE_MAX)
			croak("invalid key_type");
		tree= TreeRBXS_get_magic_tree(obj, AUTOCREATE|OR_DIE);
		if (tree->owner)
			croak("Tree is already initialized");
		tree->owner= SvRV(obj);
		tree->key_type= key_type;
		if (SvOK(compare_fn)) {
			tree->compare_callback= compare_fn;
			SvREFCNT_inc(tree->compare_callback);
		}
		tree->compare= tree->compare_callback? TreeRBXS_cmp_perl
			: key_type == KEY_TYPE_INT? TreeRBXS_cmp_int
			: key_type == KEY_TYPE_FLOAT? TreeRBXS_cmp_float
			: key_type == KEY_TYPE_STR? TreeRBXS_cmp_str
			: key_type == KEY_TYPE_ANY? TreeRBXS_cmp_str
			: NULL;
		if (!tree->compare) croak("Un-handled key comparison configuration");
		XSRETURN(1);

void
_assert_structure(tree)
	struct TreeRBXS *tree
	CODE:
		TreeRBXS_assert_structure(tree);

void
allow_duplicates(tree, allow= NULL)
	struct TreeRBXS *tree
	SV* allow
	PPCODE:
		if (items > 1) {
			tree->allow_duplicates= SvTRUE(allow);
			// ST(0) is $self, so let it be the return value
		} else {
			ST(0)= sv_2mortal(newSViv(tree->allow_duplicates? 1 : 0));
		}
		XSRETURN(1);

IV
size(tree)
	struct TreeRBXS *tree
	CODE:
		RETVAL= tree->root_sentinel.left->count;
	OUTPUT:
		RETVAL

IV
insert(tree, key, val)
	struct TreeRBXS *tree
	SV *key
	SV *val
	INIT:
		struct TreeRBXS_item *item;
		rbtree_node_t *hint= NULL;
		int cmp;
	CODE:
		//TreeRBXS_assert_structure(tree);
		if (!SvOK(key))
			croak("Can't use undef as a key");
		TreeRBXS_init_tmp_item(tree, key, val);
		item= tree->tmp_item;
		/* check for duplicates, unless they are allowed */
		//warn("Insert %p into %p", item, tree);
		if (!tree->allow_duplicates) {
			hint= rbtree_find_nearest(
				&tree->root_sentinel,
				item, // The item *is* the key that gets passed to the compare function
				(int(*)(void*,void*,void*)) tree->compare,
				tree, -OFS_TreeRBXS_item_FIELD_rbnode,
				&cmp);
		}
		if (hint && cmp == 0) {
			RETVAL= -1;
		} else {
			if (!rbtree_node_insert(
				hint? hint : &tree->root_sentinel,
				&item->rbnode,
				(int(*)(void*,void*,void*)) tree->compare,
				tree, -OFS_TreeRBXS_item_FIELD_rbnode
			)) croak("BUG: insert failed");
			/* success.  The item is no longer a temporary. */
			tree->tmp_item= NULL;
			RETVAL= rbtree_node_index(&item->rbnode);
		}
		//TreeRBXS_assert_structure(tree);
	OUTPUT:
		RETVAL

SV*
put(tree, key, val)
	struct TreeRBXS *tree
	SV *key
	SV *val
	INIT:
		struct TreeRBXS_item *item;
		rbtree_node_t *first= NULL, *last= NULL;
		int cmp;
		size_t count;
	CODE:
		if (!SvOK(key))
			croak("Can't use undef as a key");
		TreeRBXS_init_tmp_item(tree, key, val);
		RETVAL= &PL_sv_undef;
		if (rbtree_find_all(
			&tree->root_sentinel,
			tree->tmp_item, // The item *is* the key that gets passed to the compare function
			(int(*)(void*,void*,void*)) tree->compare,
			tree, -OFS_TreeRBXS_item_FIELD_rbnode,
			&first, &last, &count)
		) {
			//warn("replacing %d matching keys with new value", (int)count);
			/* prune every node that follows 'first' */
			while (last != first) {
				item= GET_TreeRBXS_item_FROM_rbnode(last);
				last= rbtree_node_prev(last);
				rbtree_node_prune(&item->rbnode);
				TreeRBXS_item_detach_tree(item, tree);
			}
			/* overwrite the value of the node */
			item= GET_TreeRBXS_item_FROM_rbnode(last);
			/* already made a copy of the value above, into the tree's tmp_value.
			   In case that was expensive, use that new SV and throw away the SV of the current node */
			if (item->value) RETVAL= item->value;
			item->value= tree->tmp_item->value;
			tree->tmp_item->value= NULL;
		}
		else {
			item= tree->tmp_item;
			if (!rbtree_node_insert(
				first? first : last? last : &tree->root_sentinel,
				&item->rbnode,
				(int(*)(void*,void*,void*)) tree->compare,
				tree, -OFS_TreeRBXS_item_FIELD_rbnode
			)) croak("BUG: insert failed");
			/* success.  The item is no longer a temporary. */
			tree->tmp_item= NULL;
		}
	OUTPUT:
		RETVAL

BOOT:
	HV* stash= gv_stashpvn("Tree::RB::XS", 12, 1);
	newCONSTSUB(stash, "KEY_TYPE_ANY",   newSViv(KEY_TYPE_ANY));
	newCONSTSUB(stash, "KEY_TYPE_INT",   newSViv(KEY_TYPE_INT));
	newCONSTSUB(stash, "KEY_TYPE_FLOAT", newSViv(KEY_TYPE_FLOAT));
	newCONSTSUB(stash, "KEY_TYPE_STR",   newSViv(KEY_TYPE_STR));

PROTOTYPES: DISABLE
