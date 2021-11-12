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

struct TreeRBXS_item {
	rbtree_node_t rbnode;
	union itemkey_u {
		IV ikey;
		NV nkey;
		SV *skey;
	} keyunion;
	SV *value;
};

static void TreeRBXS_item_free(struct TreeRBXS_item *item, struct TreeRBXS *tree) {
	switch (tree->key_type) {
	case KEY_TYPE_ANY:
	case KEY_TYPE_STR:
		SvREFCNT_dec(item->keyunion.skey);
		item->keyunion.skey= NULL;
		break;
	default: break;
	}
	Safefree(item);
}

static void TreeRBXS_destroy(struct TreeRBXS *tree) {
	rbtree_clear(&tree->root_sentinel, (void (*)(void *, void *)) &TreeRBXS_item_free, -OFS_TreeRBXS_item_FIELD_rbnode, tree);
	if (tree->tmp_item) {
		TreeRBXS_item_free(tree->tmp_item, tree);
		tree->tmp_item= NULL;
	}
}

static int TreeRBXS_cmp_int(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	return a->keyunion.ikey - b->keyunion.ikey;
}
static int TreeRBXS_cmp_str(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	return sv_cmp(a->keyunion.skey, b->keyunion.skey);
}
static int TreeRBXS_cmp_float(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	return a->keyunion.nkey - b->keyunion.nkey;
}
static int TreeRBXS_cmp_perl(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	int ret;
    dSP;
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

/* Get TreeRBXS struct attached to a Perl SV Ref.
 * Use AUTOCREATE to attach magic if it wasn't present.
 * Use OR_DIE for a built-in croak() if the return value would be NULL.
 */
static struct TreeRBXS* TreeRBXS_obj_get_struct(SV *obj, int create_flag) {
	SV *sv;
	MAGIC* magic;
    struct TreeRBXS *tree;
	if (!sv_isobject(obj)) {
		if (create_flag & OR_DIE)
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
    if (create_flag & AUTOCREATE) {
        Newxz(tree, 1, struct TreeRBXS);
        magic= sv_magicext(sv, NULL, PERL_MAGIC_ext, &TreeRBXS_magic_vt, (const char*) tree, 0);
#ifdef USE_ITHREADS
        magic->mg_flags |= MGf_DUP;
#endif
		rbtree_init_tree(&tree->root_sentinel, &tree->leaf_sentinel);
        return tree;
    }
    else if (create_flag & OR_DIE)
        croak("Object lacks 'struct TreeRBXS' magic");
	return NULL;
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
		tree= TreeRBXS_obj_get_struct(obj, AUTOCREATE|OR_DIE);
		if (tree->owner)
			croak("Tree is already initialized");
		tree->owner= SvRV(obj);
		tree->key_type= key_type;
		tree->compare_callback= SvOK(compare_fn)? compare_fn : NULL;
		tree->compare= tree->compare_callback? TreeRBXS_cmp_perl
			: key_type == KEY_TYPE_INT? TreeRBXS_cmp_int
			: key_type == KEY_TYPE_FLOAT? TreeRBXS_cmp_float
			: key_type == KEY_TYPE_STR? TreeRBXS_cmp_str
			: key_type == KEY_TYPE_ANY? TreeRBXS_cmp_str
			: NULL;
		if (!tree->compare) croak("Un-handled key comparison configuration");
		XSRETURN(1);

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

SV*
put(tree, key, val)
	struct TreeRBXS *tree
	SV *key
	SV *val
	INIT:
		struct TreeRBXS_item tmp_item, *item;
		rbtree_node_t *hint= NULL;
		SV *key_clone= NULL;
	CODE:
		if (!SvOK(key))
			croak("Can't use undef as a key");
		/* Prepare a new item with the key initialized */
		item= tree->tmp_item;
		if (item) {
			memset(&item->rbnode, 0, sizeof(item->rbnode));
		} else {
			Newxz(item, 1, struct TreeRBXS_item);
			tree->tmp_item= item; /* temporarily save the pointer on the tree to avoid awkward exception handling cleanup */
		}
		switch (tree->key_type) {
		case KEY_TYPE_STR:
		case KEY_TYPE_ANY:   if (item->keyunion.skey)
		                         sv_setsv(item->keyunion.skey, key);
		                     else
		                         item->keyunion.skey= newSVsv(key);
		                     break;
		case KEY_TYPE_INT:   item->keyunion.ikey= SvIV(key); break;
		case KEY_TYPE_FLOAT: item->keyunion.nkey= SvNV(key); break;
		default:             croak("BUG: unhandled key_type");
		}
		if (item->value)
			sv_setsv(item->value, val);
		else
			item->value= newSVsv(val);
		/* check for duplicates, unless they are allowed */
		if (!tree->allow_duplicates) {
			if (rbtree_node_search(
					tree->root_sentinel.left,
					&item->rbnode,
					(int(*)(void*,void*,void*)) tree->compare,
					tree, -OFS_TreeRBXS_item_FIELD_rbnode,
					&hint, NULL, NULL)
			) {
				croak("Tree already contains a key matching %s", SvPV_nolen(key));
			}
		}
		if (rbtree_node_insert(
			hint? hint : tree->root_sentinel.left,
			&item->rbnode,
			(int(*)(void*,void*,void*)) tree->compare,
			tree, -OFS_TreeRBXS_item_FIELD_rbnode
		)) {
			/* success.  The item is no longer a temporary. */
			tree->tmp_item= NULL;
		} else {
			croak("BUG: insert failed");
		}
		RETVAL= ST(0);
	OUTPUT:
		RETVAL

BOOT:
	HV* stash= gv_stashpvn("Tree::RB::XS", 12, 1);
	newCONSTSUB(stash, "KEY_TYPE_ANY",   newSViv(KEY_TYPE_ANY));
	newCONSTSUB(stash, "KEY_TYPE_INT",   newSViv(KEY_TYPE_INT));
	newCONSTSUB(stash, "KEY_TYPE_FLOAT", newSViv(KEY_TYPE_FLOAT));
	newCONSTSUB(stash, "KEY_TYPE_STR",   newSViv(KEY_TYPE_STR));

PROTOTYPES: DISABLE
