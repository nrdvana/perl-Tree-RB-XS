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

// Struct attached to each instance of Tree::RB::XS
struct TreeRBXS {
	SV *owner;                     // points to Tree::RB::XS internal HV (not ref)
	int key_type;                  // must always be set and never changed
	bool allow_duplicates;         // flag to affect behavior of insert.  may be changed.
	TreeRBXS_cmp_fn *compare;      // internal compare function.  Always set and never changed.
	SV *compare_callback;          // user-supplied compare.  May be NULL, but can never be changed.
	rbtree_node_t root_sentinel;   // parent-of-root, used by rbtree implementation.
	rbtree_node_t leaf_sentinel;   // dummy node used by rbtree implementation.
	struct TreeRBXS_item *tmp_item;// scratch space used by insert()
};

#define OFS_TreeRBXS_item_FIELD_rbnode ( ((char*) &(((struct TreeRBXS_item *)(void*)10000)->rbnode)) - ((char*)10000) )
#define GET_TreeRBXS_item_FROM_rbnode(node) ((struct TreeRBXS_item*) (((char*)node) - OFS_TreeRBXS_item_FIELD_rbnode))

// Struct attached to each instance of Tree::RB::XS::Node
// I named it 'item' instead of 'node' to prevent confusion with the actual
// rbtree_node_t used by the underlying library.
struct TreeRBXS_item {
	SV *owner;            // points to Tree::RB::XS::Node internal SV (not ref), or NULL if not wrapped
	rbtree_node_t rbnode; // actual red/black left/right/color/parent/count fields
	union itemkey_u {     // key variations are overlapped to save space
		IV ikey;
		NV nkey;
		SV *skey;         // This Perl SV is only valid if  (flags & TREERBXS_ITEM_SKEY)
	} keyunion;
	SV *value;            // value will be set unless struct is just used as a search key
	int key_type: 4,
		flags: 28;
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
		item->key_type= tree->key_type;
	}
	/* key_type can never change, so it is safe to assume that previous init
	 * of the item is the same as what would occur now.
	 */
	switch (tree->key_type) {
	case KEY_TYPE_STR:
	case KEY_TYPE_ANY:
		if (item->keyunion.skey)
			sv_setsv(item->keyunion.skey, key);
		else
			item->keyunion.skey= newSVsv(key);
		break;
	case KEY_TYPE_INT:   item->keyunion.ikey= SvIV(key); break;
	case KEY_TYPE_FLOAT: item->keyunion.nkey= SvNV(key); break;
	default:
		croak("BUG: un-handled key_type");
	}
	if (item->value)
		sv_setsv(item->value, value);
	else
		item->value= newSVsv(value);
}

static void TreeRBXS_item_free(struct TreeRBXS_item *item) {
	if (item->key_type == KEY_TYPE_STR || item->key_type == KEY_TYPE_ANY)
		if (item->keyunion.skey)
			SvREFCNT_dec(item->keyunion.skey);
	if (item->value)
		SvREFCNT_dec(item->value);
	Safefree(item);
}

static void TreeRBXS_item_detach_owner(struct TreeRBXS_item* item) {
	/* the MAGIC of owner doens't need changed because the only time this gets called
	   is when something else is taking care of that. */
	//if (item->owner != NULL) {
	//	TreeRBXS_set_magic_item(item->owner, NULL);
	//}
	item->owner= NULL;
	/* The tree is the other 'owner' of the node.  If the item is not in the tree,
	   then this was the last reference, and it needs freed. */
	if (!rbtree_node_is_in_tree(&item->rbnode))
		TreeRBXS_item_free(item);
}

static void TreeRBXS_item_detach_tree(struct TreeRBXS_item* item, struct TreeRBXS *unused) {
	//warn("detach tree %p %p key %d", item, tree, (int) item->keyunion.ikey);
	if (rbtree_node_is_in_tree(&item->rbnode))
		rbtree_node_prune(&item->rbnode);
	/* The item could be owned by a tree or by a Node/Iterator, or both.
	   If the tree releases the reference, the Node/Iterator will be the owner. */
	if (!item->owner)
		TreeRBXS_item_free(item);
	/* Else the tree was the only owner, and the node needs freed */
}

static void TreeRBXS_destroy(struct TreeRBXS *tree) {
	//warn("TreeRBXS_destroy");
	rbtree_clear(&tree->root_sentinel, (void (*)(void *, void *)) &TreeRBXS_item_detach_tree, -OFS_TreeRBXS_item_FIELD_rbnode, NULL);
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
 * Definitions of Perl MAGIC that attach C structs to Perl SVs
 * All instances of Tree::RB::XS have a magic-attached struct TreeRBXS
 * All instances of Tree::RB::XS::Node have a magic-attached struct TreeRBXS_item
 */

// destructor for Tree::RB::XS
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

// magic table for Tree::RB::XS
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

// destructor for Tree::RB::XS::Node
static int TreeRBXS_item_magic_free(pTHX_ SV* sv, MAGIC* mg) {
	if (mg->mg_ptr) {
		TreeRBXS_item_detach_owner((struct TreeRBXS_item*) mg->mg_ptr);
		mg->mg_ptr= NULL;
	}
	return 0;
}

// magic table for Tree::RB::XS::Node
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

// Return the TreeRBXS struct attached to a Perl object via MAGIC.
// The 'obj' should be a reference to a blessed SV.
// Use AUTOCREATE to attach magic and allocate a struct if it wasn't present.
// Use OR_DIE for a built-in croak() if the return value would be NULL.
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

// Return the TreeRBXS_item that was attached to a perl object via MAGIC.
// The 'obj' should be a referene to a blessed magical SV.
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

// Set the TreeRBXS_item pointer of some perl object to a new value.
// The 'obj' should be a reference to a blessed magical SV.
// If this perl SV already pointed to a different item, that reference is removed.
// If a different Perl SV owns this item, that reference is also removed.
// If this Perl SV already owns this item, nothing happens.
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

	item->owner= sv;

	/* If the object already owns one item, need to release that reference, possibly freeing the item */
	if (SvMAGICAL(sv)) {
        /* Iterate magic attached to this scalar, looking for one with our vtable */
		for (magic= SvMAGIC(sv); magic; magic = magic->mg_moremagic)
			if (magic->mg_type == PERL_MAGIC_ext && magic->mg_virtual == &TreeRBXS_item_magic_vt) {
				/* If found, the mg_ptr points to the fields structure. */
				if (magic->mg_ptr) {
					olditem= (struct TreeRBXS_item*) magic->mg_ptr;
					olditem->owner= NULL; // set to NULL first to prevent calling back into this function
					TreeRBXS_item_detach_owner(olditem);
				}
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

// Return existing Node object, or create a new one.
// Returned SV is a reference with active refcount, which is what the typemap
// wants for returning a "struct TreeRBXS_item*" to prel-land
static SV* TreeRBXS_wrap_item(struct TreeRBXS_item *item) {
	SV *obj, *sv;
	// Since this is used in typemap, handle NULL gracefully
	if (!item)
		return &PL_sv_undef;
	// If there is already a node object, return a new reference to it.
	if (item->owner)
		return newRV_inc(item->owner);
	// else create a node
	obj= newRV_noinc(newSV(0));
	sv_bless(obj, gv_stashpv("Tree::RB::XS::Node", GV_ADD));
	TreeRBXS_set_magic_item(obj, item);
	return obj;
}

/*----------------------------------------------------------------------------
 * Tree Methods
 */

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
		if (SvOK(compare_fn)) {
			tree->compare_callback= compare_fn;
			SvREFCNT_inc(tree->compare_callback);
			tree->key_type= KEY_TYPE_ANY;
			tree->compare= TreeRBXS_cmp_perl;
		}
		else {
			tree->key_type= key_type;
			tree->compare=
				  key_type == KEY_TYPE_INT? TreeRBXS_cmp_int
				: key_type == KEY_TYPE_FLOAT? TreeRBXS_cmp_float
				: key_type == KEY_TYPE_STR? TreeRBXS_cmp_str
				: key_type == KEY_TYPE_ANY? TreeRBXS_cmp_str
				: NULL;
			if (!tree->compare) croak("Un-handled key comparison configuration");
		}
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

void
put(tree, key, val)
	struct TreeRBXS *tree
	SV *key
	SV *val
	INIT:
		struct TreeRBXS_item *item;
		rbtree_node_t *first= NULL, *last= NULL;
		int cmp;
		size_t count;
	PPCODE:
		if (!SvOK(key))
			croak("Can't use undef as a key");
		TreeRBXS_init_tmp_item(tree, key, val);
		ST(0)= &PL_sv_undef;
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
			if (item->value) ST(0)= sv_2mortal(item->value);
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
		XSRETURN(1);

void
get(tree, key)
	struct TreeRBXS *tree
	SV *key
	INIT:
		struct TreeRBXS_item stack_item, *item;
		rbtree_node_t *node;
		int cmp;
	PPCODE:
		if (!SvOK(key))
			croak("Can't use undef as a key");
		memset(&stack_item, 0, sizeof(stack_item));
		switch (tree->key_type) {
		case KEY_TYPE_STR:
		case KEY_TYPE_ANY:   stack_item.keyunion.skey= key;       break;
		case KEY_TYPE_INT:   stack_item.keyunion.ikey= SvIV(key); break;
		case KEY_TYPE_FLOAT: stack_item.keyunion.nkey= SvNV(key); break;
		default:             croak("BUG: unhandled key_type");
		}
		ST(0)= &PL_sv_undef;
		node= rbtree_find_nearest(
			&tree->root_sentinel,
			&stack_item, // The item *is* the key that gets passed to the compare function
			(int(*)(void*,void*,void*)) tree->compare,
			tree, -OFS_TreeRBXS_item_FIELD_rbnode,
			&cmp);
		if (node && cmp == 0) {
			item= GET_TreeRBXS_item_FROM_rbnode(node);
			ST(0)= item->value;
		}
		XSRETURN(1);

struct TreeRBXS_item *
get_node(tree, key)
	struct TreeRBXS *tree
	SV *key
	INIT:
		struct TreeRBXS_item stack_item;
		rbtree_node_t *node;
		int cmp;
	CODE:
		if (!SvOK(key))
			croak("Can't use undef as a key");
		memset(&stack_item, 0, sizeof(stack_item));
		switch (tree->key_type) {
		case KEY_TYPE_STR:
		case KEY_TYPE_ANY:   stack_item.keyunion.skey= key;       break;
		case KEY_TYPE_INT:   stack_item.keyunion.ikey= SvIV(key); break;
		case KEY_TYPE_FLOAT: stack_item.keyunion.nkey= SvNV(key); break;
		default:             croak("BUG: unhandled key_type");
		}
		node= rbtree_find_nearest(
			&tree->root_sentinel,
			&stack_item, // The item *is* the key that gets passed to the compare function
			(int(*)(void*,void*,void*)) tree->compare,
			tree, -OFS_TreeRBXS_item_FIELD_rbnode,
			&cmp);
		RETVAL= (node && cmp == 0)? GET_TreeRBXS_item_FROM_rbnode(node) : NULL;
	OUTPUT:
		RETVAL

IV
delete(tree, key)
	struct TreeRBXS *tree
	SV *key
	INIT:
		struct TreeRBXS_item stack_item, *item;
		rbtree_node_t *node, *next;
		size_t count, i;
	CODE:
		if (!SvOK(key))
			croak("Can't use undef as a key");
		memset(&stack_item, 0, sizeof(stack_item));
		stack_item.key_type= tree->key_type;
		switch (tree->key_type) {
		case KEY_TYPE_STR:
		case KEY_TYPE_ANY:   stack_item.keyunion.skey= key;       break;
		case KEY_TYPE_INT:   stack_item.keyunion.ikey= SvIV(key); break;
		case KEY_TYPE_FLOAT: stack_item.keyunion.nkey= SvNV(key); break;
		default:             croak("BUG: unhandled key_type");
		}
		if (rbtree_find_all(
			&tree->root_sentinel,
			&stack_item,
			(int(*)(void*,void*,void*)) tree->compare,
			tree, -OFS_TreeRBXS_item_FIELD_rbnode,
			&node, NULL, &count)
		) {
			for (i= 0; i < count && node; i++) {
				item= GET_TreeRBXS_item_FROM_rbnode(node);
				node= rbtree_node_next(node);
				TreeRBXS_item_detach_tree(item, tree);
			}
			RETVAL= i;
		}
		else {
			RETVAL= 0;
		}
	OUTPUT:
		RETVAL

struct TreeRBXS_item *
min_node(tree)
	struct TreeRBXS *tree
	INIT:
		rbtree_node_t *node= rbtree_node_left_leaf(tree->root_sentinel.left);
	CODE:
		RETVAL= node? GET_TreeRBXS_item_FROM_rbnode(node) : NULL;
	OUTPUT:
		RETVAL

struct TreeRBXS_item *
max_node(tree)
	struct TreeRBXS *tree
	INIT:
		rbtree_node_t *node= rbtree_node_right_leaf(tree->root_sentinel.left);
	CODE:
		RETVAL= node? GET_TreeRBXS_item_FROM_rbnode(node) : NULL;
	OUTPUT:
		RETVAL

struct TreeRBXS_item *
nth_node(tree, ofs)
	struct TreeRBXS *tree
	IV ofs
	INIT:
		rbtree_node_t *node;
	CODE:
		if (ofs < 0) ofs += tree->root_sentinel.left->count;
		node= rbtree_node_child_at_index(tree->root_sentinel.left, ofs);
		RETVAL= node? GET_TreeRBXS_item_FROM_rbnode(node) : NULL;
	OUTPUT:
		RETVAL

#-----------------------------------------------------------------------------
#  Node Methods
#

MODULE = Tree::RB::XS              PACKAGE = Tree::RB::XS::Node

SV *
key(item)
	struct TreeRBXS_item *item
	CODE:
		switch (item->key_type) {
		case KEY_TYPE_ANY:
		case KEY_TYPE_STR: RETVAL= newSVsv(item->keyunion.skey); break;
		case KEY_TYPE_INT: RETVAL= newSViv(item->keyunion.ikey); break;
		case KEY_TYPE_FLOAT: RETVAL= newSVnv(item->keyunion.nkey); break;
		default: croak("BUG: un-handled key_type");
		}
	OUTPUT:
		RETVAL

SV *
value(item, newval=NULL)
	struct TreeRBXS_item *item
	SV *newval;
	CODE:
		if (newval)
			sv_setsv(item->value, newval);
		RETVAL= SvREFCNT_inc_simple_NN(item->value);
	OUTPUT:
		RETVAL

struct TreeRBXS_item *
prev(item)
	struct TreeRBXS_item *item
	INIT:
		rbtree_node_t *node= rbtree_node_prev(&item->rbnode);
	CODE:
		RETVAL= node? GET_TreeRBXS_item_FROM_rbnode(node) : NULL;
	OUTPUT:
		RETVAL

struct TreeRBXS_item *
next(item)
	struct TreeRBXS_item *item
	INIT:
		rbtree_node_t *node= rbtree_node_next(&item->rbnode);
	CODE:
		RETVAL= node? GET_TreeRBXS_item_FROM_rbnode(node) : NULL;
	OUTPUT:
		RETVAL

struct TreeRBXS_item *
parent(item)
	struct TreeRBXS_item *item
	CODE:
		RETVAL= rbtree_node_is_in_tree(&item->rbnode) && item->rbnode.parent->count?
			GET_TreeRBXS_item_FROM_rbnode(item->rbnode.parent) : NULL;
	OUTPUT:
		RETVAL

struct TreeRBXS_item *
left(item)
	struct TreeRBXS_item *item
	CODE:
		RETVAL= rbtree_node_is_in_tree(&item->rbnode) && item->rbnode.left->count?
			GET_TreeRBXS_item_FROM_rbnode(item->rbnode.left) : NULL;
	OUTPUT:
		RETVAL

struct TreeRBXS_item *
right(item)
	struct TreeRBXS_item *item
	CODE:
		RETVAL= rbtree_node_is_in_tree(&item->rbnode) && item->rbnode.right->count?
			GET_TreeRBXS_item_FROM_rbnode(item->rbnode.right) : NULL;
	OUTPUT:
		RETVAL

IV
color(item)
	struct TreeRBXS_item *item
	CODE:
		RETVAL= item->rbnode.color;
	OUTPUT:
		RETVAL

IV
count(item)
	struct TreeRBXS_item *item
	CODE:
		RETVAL= item->rbnode.count;
	OUTPUT:
		RETVAL

IV
prune(item)
	struct TreeRBXS_item *item
	CODE:
		RETVAL= 0;
		if (rbtree_node_is_in_tree(&item->rbnode)) {
			TreeRBXS_item_detach_tree(item, NULL /*unused*/);
			RETVAL= 1;
		}
	OUTPUT:
		RETVAL

#-----------------------------------------------------------------------------
#  Constants
#

BOOT:
	HV* stash= gv_stashpvn("Tree::RB::XS", 12, 1);
	newCONSTSUB(stash, "KEY_TYPE_ANY",   newSViv(KEY_TYPE_ANY));
	newCONSTSUB(stash, "KEY_TYPE_INT",   newSViv(KEY_TYPE_INT));
	newCONSTSUB(stash, "KEY_TYPE_FLOAT", newSViv(KEY_TYPE_FLOAT));
	newCONSTSUB(stash, "KEY_TYPE_STR",   newSViv(KEY_TYPE_STR));

PROTOTYPES: DISABLE
