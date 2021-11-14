#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#define AUTOCREATE 1
#define OR_DIE 2

#define KEY_TYPE_ANY   1
#define KEY_TYPE_CLAIM 2
#define KEY_TYPE_INT   3
#define KEY_TYPE_FLOAT 4
#define KEY_TYPE_BSTR  5
#define KEY_TYPE_USTR  6
#define KEY_TYPE_MAX   6

#define LU_EQ   0
#define LU_GE   1
#define LU_LE   2
#define LU_GT   3
#define LU_LT   4
#define LU_NEXT 5
#define LU_PREV 6
#define LU_MAX  6

static int parse_lookup_mode(SV *mode_sv) {
	int mode;
	size_t len;
	char *mode_str;

	mode= -1;
	if (SvIOK(mode_sv)) {
		mode= SvIV(mode_sv);
		if (mode < 0 || mode > LU_MAX)
			mode= -1;
	} else if (SvPOK(mode_sv)) {
		mode_str= SvPV(mode_sv, len);
		if (len > 3 && mode_str[0] == 'L' && mode_str[1] == 'U' && mode_str[2] == '_') {
			mode_str+= 3;
			len -= 3;
		}
		// Allow alternate syntax of "==" etc, 'eq' etc, or any of the official constant names
		switch (mode_str[0]) {
		case '<': mode= len == 1? LU_LT : len == 2 && mode_str[1] == '='? LU_LE : -1; break;
		case '>': mode= len == 1? LU_GT : len == 2 && mode_str[1] == '='? LU_GE : -1; break;
		case '=': mode= len == 2 && mode_str[1] == '='? LU_EQ : -1; break;
		case '-': mode= len == 2 && mode_str[1] == '-'? LU_PREV : -1; break;
		case '+': mode= len == 2 && mode_str[1] == '+'? LU_NEXT : -1; break;
		case 'E': case 'e':
		          mode= len == 2 && (mode_str[1] == 'q' || mode_str[1] == 'Q')? LU_EQ : -1; break;
		case 'G': case 'g':
		          mode= len == 2 && (mode_str[1] == 't' || mode_str[1] == 'T')? LU_GT
                      : len == 2 && (mode_str[1] == 'e' || mode_str[1] == 'E')? LU_GE
		              : -1;
		          break;
		case 'L': case 'l':
		          mode= len == 2 && (mode_str[1] == 't' || mode_str[1] == 'T')? LU_LT
                      : len == 2 && (mode_str[1] == 'e' || mode_str[1] == 'E')? LU_LE
		              : -1;
		          break;
		case 'P': case 'p': mode= foldEQ(mode_str, "PREV", 4)? LU_PREV : -1; break;
		case 'N': case 'n': mode= foldEQ(mode_str, "NEXT", 4)? LU_NEXT : -1; break;
		}
	}
	return mode;
}

#define EXPORT_ENUM(x) newCONSTSUB(stash, #x, new_enum_dualvar(x, newSVpvs_share(#x)))
static SV * new_enum_dualvar(IV ival, SV *name) {
	SvUPGRADE(name, SVt_PVNV);
	SvIV_set(name, ival);
	SvIOK_on(name);
	SvREADONLY_on(name);
	return name;
}

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
		const char *ckey;
		SV *svkey;
	} keyunion;
	SV *value;            // value will be set unless struct is just used as a search key
	size_t key_type: 4,
#if SIZE_MAX == 0xFFFFFFFF
#define CKEYLEN_MAX ((((size_t)1)<<28)-1)
	       ckeylen: 28;
#else
#define CKEYLEN_MAX ((((size_t)1)<<60)-1)
	       ckeylen: 60;
#endif
	char extra[];
};

static void TreeRBXS_assert_structure(struct TreeRBXS *tree) {
	int err;
	if (!tree) croak("tree is NULL");
	if (!tree->owner) croak("no owner");
	if (tree->key_type < 0 || tree->key_type > KEY_TYPE_MAX) croak("bad key_type");
	if (!tree->compare) croak("no compare function");
	if ((err= rbtree_check_structure(&tree->root_sentinel, (int(*)(void*,void*,void*)) tree->compare, tree, -OFS_TreeRBXS_item_FIELD_rbnode)))
		croak("tree structure damaged: %d", err);
	//warn("Tree is healthy");
}

/* For insert/put, there needs to be a node created before it can be
 * inserted.  But if the insert fails, the item needs cleaned up.
 * This initializes a temporary incomplete item on the stack that can be
 * used for searching without the expense of allocating buffers etc.
 * The temporary item does not require any destructor/cleanup.
 */
static void TreeRBXS_init_tmp_item(struct TreeRBXS_item *item, struct TreeRBXS *tree, SV *key, SV *value) {
	size_t len= 0;

	// all fields should start NULL just to be safe
	memset(item, 0, sizeof(*item));
	// copy key type from tree
	item->key_type= tree->key_type;
	// set up the keys.  
	switch (item->key_type) {
	case KEY_TYPE_ANY:
	case KEY_TYPE_CLAIM: item->keyunion.svkey= key; break;
	case KEY_TYPE_INT:   item->keyunion.ikey= SvIV(key); break;
	case KEY_TYPE_FLOAT: item->keyunion.nkey= SvNV(key); break;
	// STR and BSTR assume that the 'key' SV has a longer lifespan than the use of the tmp item,
	// and directly reference the PV pointer.  The insert and search algorithms should not be
	// calling into Perl for their entire execution.
	case KEY_TYPE_USTR:
		item->keyunion.ckey= SvPVutf8(key, len);
		if (0)
	case KEY_TYPE_BSTR:
			item->keyunion.ckey= SvPVbyte(key, len);
		// the ckeylen is a bit field, so can't go the full range of size_t
		if (len > CKEYLEN_MAX)
			croak("String length %ld exceeds maximum %ld for optimized key_type", (long)len, CKEYLEN_MAX);
		item->ckeylen= len;
		break;
	default:
		croak("BUG: un-handled key_type");
	}
	item->value= value;
}

/* When insert has decided that the temporary node is permitted ot be inserted,
 * this function allocates a real item struct with its own reference counts
 * and buffer data, etc.
 */
static struct TreeRBXS_item * TreeRBXS_new_item_from_tmp_item(struct TreeRBXS_item *src) {
	struct TreeRBXS_item *dst;
	size_t len;
	/* If the item references a string that is nor managed by a SV,
	  copy that into the space at the end of the allocated block. */
	if (src->key_type == KEY_TYPE_USTR || src->key_type == KEY_TYPE_BSTR) {
		len= src->ckeylen;
		Newxc(dst, sizeof(struct TreeRBXS_item) + len + 1, char, struct TreeRBXS_item);
		memset(dst, 0, sizeof(struct TreeRBXS_item));
		memcpy(dst->extra, src->keyunion.ckey, len);
		dst->extra[len]= '\0';
		dst->keyunion.ckey= dst->extra;
		dst->ckeylen= src->ckeylen;
	}
	else {
		Newxz(dst, 1, struct TreeRBXS_item);
		switch (src->key_type) {
		case KEY_TYPE_ANY:   dst->keyunion.svkey= newSVsv(src->keyunion.svkey);
			if (0)
		case KEY_TYPE_CLAIM: dst->keyunion.svkey= SvREFCNT_inc(src->keyunion.svkey);
			SvREADONLY_on(dst->keyunion.svkey);
			break;
		case KEY_TYPE_INT:   dst->keyunion.ikey=  src->keyunion.ikey; break;
		case KEY_TYPE_FLOAT: dst->keyunion.nkey=  src->keyunion.nkey; break;
		default:
			croak("BUG: un-handled key_type %d", src->key_type);
		}
	}
	dst->key_type= src->key_type;
	dst->value= newSVsv(src->value);
	return dst;
}

static void TreeRBXS_item_free(struct TreeRBXS_item *item) {
	switch (item->key_type) {
	case KEY_TYPE_ANY:
	case KEY_TYPE_CLAIM: SvREFCNT_dec(item->keyunion.svkey); break;
	}
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
	if (tree->compare_callback)
		SvREFCNT_dec(tree->compare_callback);
}

// Compare integers which were both already decoded from the original SVs
static int TreeRBXS_cmp_int(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	//warn("  int compare %p (%d) <=> %p (%d)", a, (int)a->keyunion.ikey, b, (int)b->keyunion.ikey);
	IV diff= a->keyunion.ikey - b->keyunion.ikey;
	return diff < 0? -1 : diff > 0? 1 : 0; /* shrink from IV to int might lose upper bits */
}

// Compare floats which were both already decoded form the original SVs
static int TreeRBXS_cmp_float(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	NV diff= a->keyunion.nkey - b->keyunion.nkey;
	return diff < 0? -1 : diff > 0? 1 : 0;
}

// Compare C strings sing memcmp, on raw byte values.  This isn't correct for UTF-8 but is a tradeoff for speed.
static int TreeRBXS_cmp_memcmp(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	size_t alen= a->ckeylen, blen= b->ckeylen;
	int cmp= memcmp(a->keyunion.ckey, b->keyunion.ckey, alen < blen? alen : blen);
	return cmp? cmp : alen < blen? -1 : alen > blen? 1 : 0;
}

// Compare SV items using Perl's 'cmp' operator
static int TreeRBXS_cmp_perl(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	return sv_cmp(a->keyunion.svkey, b->keyunion.svkey);
}

// Compare SV items using a user-supplied perl callback
static int TreeRBXS_cmp_perl_cb(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	int ret;
    dSP;
    ENTER;
	// There are a max of $tree_depth comparisons to do during an insert or search,
	// so should be safe to not free temporaries for a little bit.
    PUSHMARK(SP);
    EXTEND(SP, 2);
    PUSHs(a->keyunion.svkey);
    PUSHs(b->keyunion.svkey);
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
	SV *sv;
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
			croak("invalid key_type %d", key_type);
		tree= TreeRBXS_get_magic_tree(obj, AUTOCREATE|OR_DIE);
		if (tree->owner)
			croak("Tree is already initialized");
		tree->owner= SvRV(obj);
		// If there is a user-supplied compare function, it mandates the use of
		// KEY_TYPE_ANY no matter what the user asked for.
		if (SvOK(compare_fn)) {
			tree->compare_callback= compare_fn;
			SvREFCNT_inc(tree->compare_callback);
			tree->key_type= key_type == KEY_TYPE_CLAIM? key_type : KEY_TYPE_ANY;
			tree->compare= TreeRBXS_cmp_perl_cb;
		}
		else {
			tree->key_type= key_type;
			tree->compare=
				  key_type == KEY_TYPE_INT? TreeRBXS_cmp_int
				: key_type == KEY_TYPE_FLOAT? TreeRBXS_cmp_float
				: key_type == KEY_TYPE_USTR? TreeRBXS_cmp_memcmp
				: key_type == KEY_TYPE_BSTR? TreeRBXS_cmp_memcmp
				: key_type == KEY_TYPE_ANY? TreeRBXS_cmp_perl /* use Perl's cmp operator */
				: key_type == KEY_TYPE_CLAIM? TreeRBXS_cmp_perl
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
		struct TreeRBXS_item stack_item, *item;
		rbtree_node_t *hint= NULL;
		int cmp= 0;
	CODE:
		//TreeRBXS_assert_structure(tree);
		if (!SvOK(key))
			croak("Can't use undef as a key");
		TreeRBXS_init_tmp_item(&stack_item, tree, key, val);
		/* check for duplicates, unless they are allowed */
		//warn("Insert %p into %p", item, tree);
		if (!tree->allow_duplicates) {
			hint= rbtree_find_nearest(
				&tree->root_sentinel,
				&stack_item, // The item *is* the key that gets passed to the compare function
				(int(*)(void*,void*,void*)) tree->compare,
				tree, -OFS_TreeRBXS_item_FIELD_rbnode,
				&cmp);
		}
		if (hint && cmp == 0) {
			RETVAL= -1;
		} else {
			item= TreeRBXS_new_item_from_tmp_item(&stack_item);
			if (!rbtree_node_insert(
				hint? hint : &tree->root_sentinel,
				&item->rbnode,
				(int(*)(void*,void*,void*)) tree->compare,
				tree, -OFS_TreeRBXS_item_FIELD_rbnode
			)) {
				TreeRBXS_item_free(item);
				croak("BUG: insert failed");
			}
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
		struct TreeRBXS_item stack_item, *item;
		rbtree_node_t *first= NULL, *last= NULL;
		size_t count;
	PPCODE:
		if (!SvOK(key))
			croak("Can't use undef as a key");
		TreeRBXS_init_tmp_item(&stack_item, tree, key, val);
		ST(0)= &PL_sv_undef;
		if (rbtree_find_all(
			&tree->root_sentinel,
			&stack_item, // The item *is* the key that gets passed to the compare function
			(int(*)(void*,void*,void*)) tree->compare,
			tree, -OFS_TreeRBXS_item_FIELD_rbnode,
			&first, &last, &count)
		) {
			//warn("replacing %d matching keys with new value", (int)count);
			// prune every node that follows 'first'
			while (last != first) {
				item= GET_TreeRBXS_item_FROM_rbnode(last);
				last= rbtree_node_prev(last);
				rbtree_node_prune(&item->rbnode);
				TreeRBXS_item_detach_tree(item, tree);
			}
			/* overwrite the value of the node */
			item= GET_TreeRBXS_item_FROM_rbnode(first);
			val= newSVsv(val);
			ST(0)= sv_2mortal(item->value); // return the old value
			item->value= val; // sore new copy of supplied param
		}
		else {
			item= TreeRBXS_new_item_from_tmp_item(&stack_item);
			if (!rbtree_node_insert(
				first? first : last? last : &tree->root_sentinel,
				&item->rbnode,
				(int(*)(void*,void*,void*)) tree->compare,
				tree, -OFS_TreeRBXS_item_FIELD_rbnode
			)) {
				TreeRBXS_item_free(item);
				croak("BUG: insert failed");
			}
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
		TreeRBXS_init_tmp_item(&stack_item, tree, key, &PL_sv_undef);
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

void
get_all(tree, key)
	struct TreeRBXS *tree
	SV *key
	INIT:
		struct TreeRBXS_item stack_item, *item;
		rbtree_node_t *first;
		size_t count, i;
	PPCODE:
		if (!SvOK(key))
			croak("Can't use undef as a key");
		TreeRBXS_init_tmp_item(&stack_item, tree, key, &PL_sv_undef);
		if (rbtree_find_all(
			&tree->root_sentinel,
			&stack_item,
			(int(*)(void*,void*,void*)) tree->compare,
			tree, -OFS_TreeRBXS_item_FIELD_rbnode,
			&first, NULL, &count)
		) {
			EXTEND(SP, count);
			for (i= 0; i < count; i++) {
				item= GET_TreeRBXS_item_FROM_rbnode(first);
				ST(i)= item->value;
				first= rbtree_node_next(first);
			}
		} else
			count= 0;
		XSRETURN(count);

void
lookup(tree, key, mode_sv)
	struct TreeRBXS *tree
	SV *key
	SV *mode_sv
	INIT:
		struct TreeRBXS_item stack_item, *item;
		rbtree_node_t *first, *last, *node= NULL;
		int cmp, mode, len;
		const char *mode_str;
	PPCODE:
		if (!SvOK(key))
			croak("Can't use undef as a key");
		if ((mode= parse_lookup_mode(mode_sv)) < 0)
			croak("Invalid lookup mode %s", SvPV_nolen(mode_sv));

		TreeRBXS_init_tmp_item(&stack_item, tree, key, &PL_sv_undef);
		ST(0)= &PL_sv_undef;
		if (rbtree_find_all(
			&tree->root_sentinel,
			&stack_item,
			(int(*)(void*,void*,void*)) tree->compare,
			tree, -OFS_TreeRBXS_item_FIELD_rbnode,
			&first, &last, NULL)
		) {
			// Found an exact match.  First and last are the range of nodes matching.
			switch (mode) {
			case LU_EQ:
			case LU_GE:
			case LU_LE: node= first; break;
			case LU_LT:
			case LU_PREV: node= rbtree_node_prev(first); break;
			case LU_GT:
			case LU_NEXT: node= rbtree_node_next(last); break;
			default: croak("BUG: unhandled mode");
			}
		} else {
			// Didn't find an exact match.  First and last are the bounds of what would have matched.
			switch (mode) {
			case LU_EQ: node= NULL; break;
			case LU_GE:
			case LU_GT: node= last; break;
			case LU_LE:
			case LU_LT: node= first; break;
			case LU_PREV:
			case LU_NEXT: node= NULL; break;
			default: croak("BUG: unhandled mode");
			}
		}
		if (node) {
			item= GET_TreeRBXS_item_FROM_rbnode(node);
			ST(0)= item->value;
			if (GIMME_V == G_ARRAY)
				ST(1)= sv_2mortal(TreeRBXS_wrap_item(item));
		} else {
			ST(0)= &PL_sv_undef;
			if (GIMME_V == G_ARRAY)
				ST(1)= &PL_sv_undef;
		}
		XSRETURN(GIMME_V == G_ARRAY? 2 : 1);

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
		TreeRBXS_init_tmp_item(&stack_item, tree, key, &PL_sv_undef);
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
		rbtree_node_t *node;
		size_t count, i;
	CODE:
		if (!SvOK(key))
			croak("Can't use undef as a key");
		TreeRBXS_init_tmp_item(&stack_item, tree, key, &PL_sv_undef);
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
		case KEY_TYPE_CLAIM: RETVAL= SvREFCNT_inc(item->keyunion.svkey); break;
		case KEY_TYPE_INT:   RETVAL= newSViv(item->keyunion.ikey); break;
		case KEY_TYPE_FLOAT: RETVAL= newSVnv(item->keyunion.nkey); break;
		case KEY_TYPE_USTR:  RETVAL= newSVpvn_flags(item->keyunion.ckey, item->ckeylen, SVf_UTF8); break;
		case KEY_TYPE_BSTR:  RETVAL= newSVpvn(item->keyunion.ckey, item->ckeylen); break;
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

IV
index(item)
	struct TreeRBXS_item *item
	CODE:
		RETVAL= rbtree_node_index(&item->rbnode);
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
	EXPORT_ENUM(KEY_TYPE_ANY);
	EXPORT_ENUM(KEY_TYPE_INT);
	EXPORT_ENUM(KEY_TYPE_FLOAT);
	EXPORT_ENUM(KEY_TYPE_USTR);
	EXPORT_ENUM(KEY_TYPE_BSTR);
	EXPORT_ENUM(KEY_TYPE_CLAIM);
	EXPORT_ENUM(LU_EQ);
	EXPORT_ENUM(LU_GE);
	EXPORT_ENUM(LU_LE);
	EXPORT_ENUM(LU_GT);
	EXPORT_ENUM(LU_LT);
	EXPORT_ENUM(LU_NEXT);
	EXPORT_ENUM(LU_PREV);

PROTOTYPES: DISABLE
