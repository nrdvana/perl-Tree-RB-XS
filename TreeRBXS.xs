#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

/* The core Red/Black algorithm which operates on rbtree_node_t */
#include "rbtree.h"

struct TreeRBXS;
struct TreeRBXS_item;

#define AUTOCREATE 1
#define OR_DIE 2

#define KEY_TYPE_ANY   1
#define KEY_TYPE_CLAIM 2
#define KEY_TYPE_INT   3
#define KEY_TYPE_FLOAT 4
#define KEY_TYPE_BSTR  5
#define KEY_TYPE_USTR  6
#define KEY_TYPE_MAX   6

static int parse_key_type(SV *type_sv) {
	const char *str;
	size_t len;
	int key_type= -1;
	if (SvIOK(type_sv)) {
		key_type= SvIV(type_sv);
		if (key_type < 1 || key_type > KEY_TYPE_MAX)
			key_type= -1;
	}
	else if (SvPOK(type_sv)) {
		str= SvPV(type_sv, len);
		if (len > 9 && foldEQ(str, "KEY_TYPE_", 9)) {
			str += 9;
			len -= 9;
		}
		key_type= (len == 3 && foldEQ(str, "ANY",   3))? KEY_TYPE_ANY
		        : (len == 5 && foldEQ(str, "CLAIM", 5))? KEY_TYPE_CLAIM
		        : (len == 3 && foldEQ(str, "INT",   3))? KEY_TYPE_INT
		        : (len == 5 && foldEQ(str, "FLOAT", 5))? KEY_TYPE_FLOAT
		        : (len == 4 && foldEQ(str, "BSTR",  4))? KEY_TYPE_BSTR
		        : (len == 4 && foldEQ(str, "USTR",  4))? KEY_TYPE_USTR
		        : -1;
	}
	return key_type;
}

static const char *get_key_type_name(int key_type) {
	switch (key_type) {
	case KEY_TYPE_ANY:   return "KEY_TYPE_ANY";
	case KEY_TYPE_CLAIM: return "KEY_TYPE_CLAIM";
	case KEY_TYPE_INT:   return "KEY_TYPE_INT";
	case KEY_TYPE_FLOAT: return "KEY_TYPE_FLOAT";
	case KEY_TYPE_BSTR:  return "KEY_TYPE_BSTR";
	case KEY_TYPE_USTR:  return "KEY_TYPE_USTR";
	default: return NULL;
	}
}

typedef int TreeRBXS_cmp_fn(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b);
static TreeRBXS_cmp_fn TreeRBXS_cmp_int;
static TreeRBXS_cmp_fn TreeRBXS_cmp_float;
static TreeRBXS_cmp_fn TreeRBXS_cmp_memcmp;
static TreeRBXS_cmp_fn TreeRBXS_cmp_utf8;
static TreeRBXS_cmp_fn TreeRBXS_cmp_numsplit;
static TreeRBXS_cmp_fn TreeRBXS_cmp_perl;
static TreeRBXS_cmp_fn TreeRBXS_cmp_perl_cb;

#define CMP_PERL    1
#define CMP_INT     2
#define CMP_FLOAT   3
#define CMP_MEMCMP  4
#define CMP_UTF8    5
#define CMP_SUB     6
#define CMP_NUMSPLIT 7
#define CMP_MAX     7

static int parse_cmp_fn(SV *cmp_sv) {
	const char *str;
	size_t len;
	int cmp_id= -1;
	if (SvROK(cmp_sv) && SvTYPE(SvRV(cmp_sv)) == SVt_PVCV)
		cmp_id= CMP_SUB;
	else if (SvIOK(cmp_sv)) {
		cmp_id= SvIV(cmp_sv);
		if (cmp_id < 1 || cmp_id > CMP_MAX || cmp_id == CMP_SUB)
			cmp_id= -1;
	}
	else if (SvPOK(cmp_sv)) {
		str= SvPV(cmp_sv, len);
		if (len > 4 && foldEQ(str, "CMP_", 4)) {
			str += 4;
			len -= 4;
		}
		cmp_id= (len == 4 && foldEQ(str, "PERL",   4))? CMP_PERL
		      : (len == 3 && foldEQ(str, "INT",    3))? CMP_INT
		      : (len == 5 && foldEQ(str, "FLOAT",  5))? CMP_FLOAT
		      : (len == 6 && foldEQ(str, "MEMCMP", 6))? CMP_MEMCMP
		      : (len == 4 && foldEQ(str, "UTF8",   4))? CMP_UTF8
		      : (len == 8 && foldEQ(str, "NUMSPLIT", 8))? CMP_NUMSPLIT
		    //: (len == 7 && foldEQ(str, "SUB",    3))? CMP_SUB   can only be requested by a CV*
		      : -1;
	}
	return cmp_id;
}

static const char * get_cmp_name(int cmp_id) {
	switch (cmp_id) {
	case CMP_PERL:   return "CMP_PERL";
	case CMP_INT:    return "CMP_INT";
	case CMP_FLOAT:  return "CMP_FLOAT";
	case CMP_MEMCMP: return "CMP_MEMCMP";
	case CMP_UTF8:   return "CMP_UTF8";
	case CMP_NUMSPLIT: return "CMP_NUMSPLIT";
	default: return NULL;
	}
}

#define GET_EQ   0
#define GET_GE   1
#define GET_LE   2
#define GET_GT   3
#define GET_LT   4
#define GET_NEXT 5
#define GET_PREV 6
#define GET_EQ_LAST 7
#define GET_LE_LAST 8
#define GET_MAX  8

static int parse_lookup_mode(SV *mode_sv) {
	int mode;
	size_t len;
	char *mode_str;

	mode= -1;
	if (SvIOK(mode_sv)) {
		mode= SvIV(mode_sv);
		if (mode < 0 || mode > GET_MAX)
			mode= -1;
	} else if (SvPOK(mode_sv)) {
		mode_str= SvPV(mode_sv, len);
		if (len > 4 && foldEQ(mode_str, "GET_", 4)) {
			mode_str+= 4;
			len -= 4;
		}
		// Allow alternate syntax of "==" etc, 'eq' etc, or any of the official constant names
		switch (mode_str[0]) {
		case '<': mode= len == 1? GET_LT : len == 2 && mode_str[1] == '='? GET_LE : -1; break;
		case '>': mode= len == 1? GET_GT : len == 2 && mode_str[1] == '='? GET_GE : -1; break;
		case '=': mode= len == 2 && mode_str[1] == '='? GET_EQ : -1; break;
		case '-': mode= len == 2 && mode_str[1] == '-'? GET_PREV : -1; break;
		case '+': mode= len == 2 && mode_str[1] == '+'? GET_NEXT : -1; break;
		case 'E': case 'e':
		          mode= len == 2 && (mode_str[1] == 'q' || mode_str[1] == 'Q')? GET_EQ
		              : len == 7 && foldEQ(mode_str, "EQ_LAST", 7)? GET_EQ_LAST
		              : -1;
		          break;
		case 'G': case 'g':
		          mode= len == 2 && (mode_str[1] == 't' || mode_str[1] == 'T')? GET_GT
                      : len == 2 && (mode_str[1] == 'e' || mode_str[1] == 'E')? GET_GE
		              : -1;
		          break;
		case 'L': case 'l':
		          mode= len == 2 && (mode_str[1] == 't' || mode_str[1] == 'T')? GET_LT
                      : len == 2 && (mode_str[1] == 'e' || mode_str[1] == 'E')? GET_LE
		              : len == 7 && foldEQ(mode_str, "LE_LAST", 7)? GET_LE_LAST
		              : -1;
		          break;
		case 'P': case 'p': mode= foldEQ(mode_str, "PREV", 4)? GET_PREV : -1; break;
		case 'N': case 'n': mode= foldEQ(mode_str, "NEXT", 4)? GET_NEXT : -1; break;
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

// Struct attached to each instance of Tree::RB::XS
struct TreeRBXS {
	SV *owner;                     // points to Tree::RB::XS internal HV (not ref)
	TreeRBXS_cmp_fn *compare;      // internal compare function.  Always set and never changed.
	SV *compare_callback;          // user-supplied compare.  May be NULL, but can never be changed.
	int key_type;                  // must always be set and never changed
	int compare_fn_id;             // indicates which compare is in use, for debugging
	bool allow_duplicates;         // flag to affect behavior of insert.  may be changed.
	bool compat_list_get;          // flag to enable full compat with Tree::RB's list context behavior
	rbtree_node_t root_sentinel;   // parent-of-root, used by rbtree implementation.
	rbtree_node_t leaf_sentinel;   // dummy node used by rbtree implementation.
};

#define OFS_TreeRBXS_FIELD_root_sentinel ( ((char*) &(((struct TreeRBXS*)(void*)10000)->root_sentinel)) - ((char*)10000) )
#define GET_TreeRBXS_FROM_root_sentinel(node) ((struct TreeRBXS*) (((char*)node) - OFS_TreeRBXS_FIELD_root_sentinel))

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

static struct TreeRBXS* TreeRBXS_item_get_tree(struct TreeRBXS_item *item) {
	rbtree_node_t *node= rbtree_node_rootsentinel(&item->rbnode);
	return node? GET_TreeRBXS_FROM_root_sentinel(node) : NULL;
}

static void TreeRBXS_item_free(struct TreeRBXS_item *item) {
	//warn("TreeRBXS_item_free");
	switch (item->key_type) {
	case KEY_TYPE_ANY:
	case KEY_TYPE_CLAIM: SvREFCNT_dec(item->keyunion.svkey); break;
	}
	if (item->value)
		SvREFCNT_dec(item->value);
	Safefree(item);
}

static void TreeRBXS_item_detach_owner(struct TreeRBXS_item* item) {
	//warn("TreeRBXS_item_detach_owner");
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
	//warn("TreeRBXS_item_detach_tree");
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

static int TreeRBXS_cmp_utf8(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	return bytes_cmp_utf8(
		(unsigned char*)a->keyunion.ckey, a->ckeylen,
		(unsigned char*)b->keyunion.ckey, b->ckeylen
	);
}

static int TreeRBXS_cmp_numsplit(struct TreeRBXS *tree, struct TreeRBXS_item *a, struct TreeRBXS_item *b) {
	const char *apos, *alim, *amark;
	const char *bpos, *blim, *bmark;
	size_t alen, blen;
	int cmp;

	switch (tree->key_type) {
	case KEY_TYPE_USTR:
	case KEY_TYPE_BSTR:
		apos= a->keyunion.ckey; alim= apos + a->ckeylen;
		bpos= b->keyunion.ckey; blim= bpos + b->ckeylen;
		break;
	case KEY_TYPE_ANY:
	case KEY_TYPE_CLAIM:
		apos= SvPV(a->keyunion.svkey, alen); alim= apos + alen;
		bpos= SvPV(b->keyunion.svkey, blen); blim= bpos + blen;
		break;
	default: croak("BUG");
	}

	while (apos < alim && bpos < blim) {
		// find the next start of digits along the strings
		amark= apos;
		while (apos < alim && !isdigit(*apos)) apos++;
		bmark= bpos;
		while (bpos < blim && !isdigit(*bpos)) bpos++;
		alen= apos - amark;
		blen= bpos - bmark;
		// compare the non-digit portions found in each string
		if (alen || blen) {
			// If one of the non-digit spans was length=0, then we are comparing digits
			// with string, and digits sort first.
			if (alen == 0) return -1;
			if (blen == 0) return 1;
			// else compare the portions in common.
			if (tree->key_type != KEY_TYPE_BSTR) {
				cmp= bytes_cmp_utf8((unsigned char*)amark, alen, (unsigned char*)bmark, blen);
				if (cmp) return cmp;
			} else {
				cmp= memcmp(amark, bmark, alen < blen? alen : blen);
				if (cmp) return cmp;
				if (alen < blen) return -1;
				if (alen > blen) return -1;
			}
		}
		// If one of the strings ran out of characters, it is the lesser one.
		if (!(apos < alim && bpos < blim)) break;
		// compare the digit portions found in each string
		// Find the start and end of nonzero digits in A
		while (apos < alim && *apos == '0') apos++;
		amark= apos;
		while (apos < alim && isdigit(*apos)) apos++;
		// Find the start and end of nonzero digits in B
		while (bpos < blim && *bpos == '0') bpos++;
		bmark= bpos;
		while (bpos < blim && isdigit(*bpos)) bpos++;
		// Whichever number is longr is greater
		alen= apos - amark;
		blen= bpos - bmark;
		if (alen < blen) return -1;
		if (alen > blen) return 1;
		// Else they're the same length, so strcmp to find the winner.
		cmp= memcmp(amark, bmark, alen);
		if (cmp) return cmp;
		// Else they're equal, continue to the next component.
	}
	// One or both of the strings ran out of characters
	if (bpos < blim) return -1;
	if (apos < alim) return 1;
	return 0;
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
// The 'obj' should be a reference to a blessed magical SV.
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
	SV *obj;
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
_init_tree(obj, key_type_sv, compare_fn)
	SV *obj
	SV *key_type_sv;
	SV *compare_fn;
	INIT:
		struct TreeRBXS *tree;
		int key_type;
		int cmp_id= 0;
	PPCODE:
		// Must be called on a blessed hashref
		if (!sv_isobject(obj) || SvTYPE(SvRV(obj)) != SVt_PVHV)
			croak("_init_tree called on non-object");
		
		// parse key type and compare_fn
		key_type= SvOK(key_type_sv)? parse_key_type(key_type_sv) : 0;
		if (key_type < 0)
			croak("invalid key_type %s", SvPV_nolen(key_type_sv));
		
		if (SvOK(compare_fn)) {
			cmp_id= parse_cmp_fn(compare_fn);
			if (cmp_id < 0)
				croak("invalid compare_fn %s", SvPV_nolen(compare_fn));
		} else {
			cmp_id= key_type == KEY_TYPE_INT?   CMP_INT
			      : key_type == KEY_TYPE_FLOAT? CMP_FLOAT
			      : key_type == KEY_TYPE_BSTR?  CMP_MEMCMP
			      : key_type == KEY_TYPE_USTR?  CMP_UTF8
			      : key_type == KEY_TYPE_ANY?   CMP_PERL /* use Perl's cmp operator */
			      : key_type == KEY_TYPE_CLAIM? CMP_PERL
			      : CMP_PERL;
		}
		
		tree= TreeRBXS_get_magic_tree(obj, AUTOCREATE|OR_DIE);
		if (tree->owner)
			croak("Tree is already initialized");
		
		tree->owner= SvRV(obj);
		tree->compare_fn_id= cmp_id;
		switch (cmp_id) {
		case CMP_SUB:
			tree->compare_callback= compare_fn;
			SvREFCNT_inc(tree->compare_callback);
			tree->key_type= key_type == KEY_TYPE_CLAIM? key_type : KEY_TYPE_ANY;
			tree->compare= TreeRBXS_cmp_perl_cb;
			break;
		case CMP_PERL:
			tree->key_type= key_type == KEY_TYPE_CLAIM? key_type : KEY_TYPE_ANY;
			tree->compare= TreeRBXS_cmp_perl;
			break;
		case CMP_INT:
			tree->key_type= KEY_TYPE_INT;
			tree->compare= TreeRBXS_cmp_int;
			break;
		case CMP_FLOAT:
			tree->key_type= KEY_TYPE_FLOAT;
			tree->compare= TreeRBXS_cmp_float;
			break;
		case CMP_MEMCMP:
			tree->key_type= KEY_TYPE_BSTR;
			tree->compare= TreeRBXS_cmp_memcmp;
			break;
		case CMP_UTF8:
			tree->key_type= KEY_TYPE_USTR;
			tree->compare= TreeRBXS_cmp_utf8;
			break;
		case CMP_NUMSPLIT:
			tree->key_type= key_type == KEY_TYPE_BSTR || key_type == KEY_TYPE_USTR
				|| key_type == KEY_TYPE_ANY || key_type == KEY_TYPE_CLAIM? key_type : KEY_TYPE_BSTR;
			tree->compare= TreeRBXS_cmp_numsplit;
			break;
		default:
			croak("BUG: unhandled cmp_id");
		}
		XSRETURN(1);

void
_assert_structure(tree)
	struct TreeRBXS *tree
	CODE:
		TreeRBXS_assert_structure(tree);

void
key_type(tree)
	struct TreeRBXS *tree
	INIT:
		int kt= tree->key_type;
	PPCODE:
		ST(0)= sv_2mortal(new_enum_dualvar(kt, newSVpv(get_key_type_name(kt), 0)));
		XSRETURN(1);

void
compare_fn(tree)
	struct TreeRBXS *tree
	INIT:
		int id= tree->compare_fn_id;
	PPCODE:
		ST(0)= id == CMP_SUB? tree->compare_callback
			: sv_2mortal(new_enum_dualvar(id, newSVpv(get_cmp_name(id), 0)));
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

void
compat_list_get(tree, allow= NULL)
	struct TreeRBXS *tree
	SV* allow
	PPCODE:
		if (items > 1) {
			tree->compat_list_get= SvTRUE(allow);
			// ST(0) is $self, so let it be the return value
		} else {
			ST(0)= sv_2mortal(newSViv(tree->compat_list_get? 1 : 0));
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
get(tree, key, mode_sv= NULL)
	struct TreeRBXS *tree
	SV *key
	SV *mode_sv
	ALIAS:
		Tree::RB::XS::lookup           = 0
		Tree::RB::XS::get              = 1
		Tree::RB::XS::get_node         = 2
		Tree::RB::XS::get_node_last    = 3
		Tree::RB::XS::get_node_le      = 4
		Tree::RB::XS::get_node_le_last = 5
		Tree::RB::XS::get_node_lt      = 6
		Tree::RB::XS::get_node_gt      = 7
		Tree::RB::XS::get_node_ge      = 8
	INIT:
		struct TreeRBXS_item stack_item, *item;
		rbtree_node_t *first, *last, *node= NULL;
		int cmp, mode;
	PPCODE:
		if (!SvOK(key))
			croak("Can't use undef as a key");
		switch (ix) {
		// In "full compatibility mode", 'get' is identical to 'lookup'
		case 1:
			if (tree->compat_list_get) {
				ix= 0;
		// In scalar context, lookup is identical to 'get'
		case 0: if (GIMME_V == G_SCALAR) ix= 1;
			}
		case 2:
			mode= mode_sv? parse_lookup_mode(mode_sv) : GET_EQ;
			if (mode < 0)
				croak("Invalid lookup mode %s", SvPV_nolen(mode_sv));
			break;
		case 3: mode= GET_EQ_LAST; if (0)
		case 4: mode= GET_LE;      if (0)
		case 5: mode= GET_LE_LAST; if (0)
		case 6: mode= GET_LT;      if (0)
		case 7: mode= GET_GT;      if (0)
		case 8: mode= GET_GE;
			if (mode_sv) croak("extra get-mode argument");
			ix= 2;
			break;
		}
		// create a fake item to act as a search key
		TreeRBXS_init_tmp_item(&stack_item, tree, key, &PL_sv_undef);
		// Need to ensure we find the *first* matching node for a key,
		// to deal with the case of duplicate keys.
		if (rbtree_find_all(
			&tree->root_sentinel,
			&stack_item,
			(int(*)(void*,void*,void*)) tree->compare,
			tree, -OFS_TreeRBXS_item_FIELD_rbnode,
			&first, &last, NULL)
		) {
			// Found an exact match.  First and last are the range of nodes matching.
			switch (mode) {
			case GET_EQ:
			case GET_GE:
			case GET_LE: node= first; break;
			case GET_EQ_LAST:
			case GET_LE_LAST: node= last; break;
			case GET_LT:
			case GET_PREV: node= rbtree_node_prev(first); break;
			case GET_GT:
			case GET_NEXT: node= rbtree_node_next(last); break;
			default: croak("BUG: unhandled mode");
			}
		} else {
			// Didn't find an exact match.  First and last are the bounds of what would have matched.
			switch (mode) {
			case GET_EQ:
			case GET_EQ_LAST: node= NULL; break;
			case GET_GE:
			case GET_GT: node= last; break;
			case GET_LE:
			case GET_LE_LAST:
			case GET_LT: node= first; break;
			case GET_PREV:
			case GET_NEXT: node= NULL; break;
			default: croak("BUG: unhandled mode");
			}
		}
		if (node) {
			item= GET_TreeRBXS_item_FROM_rbnode(node);
			if (ix == 0) { // lookup in list context
				ST(0)= item->value;
				ST(1)= sv_2mortal(TreeRBXS_wrap_item(item));
				XSRETURN(2);
			} else if (ix == 1) { // get, or lookup in scalar context
				ST(0)= item->value;
				XSRETURN(1);
			} else { // get_node
				ST(0)= sv_2mortal(TreeRBXS_wrap_item(item));
				XSRETURN(1);
			}
		} else {
			if (ix == 0) { // lookup in list context
				XSRETURN(0);
			}
			else {
				ST(0)= &PL_sv_undef;
				XSRETURN(1);
			}
		}

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

IV
delete(tree, key1, key2= NULL)
	struct TreeRBXS *tree
	SV *key1
	SV *key2
	INIT:
		struct TreeRBXS_item stack_item, *item;
		rbtree_node_t *first, *last, *node;
		size_t count, i;
	CODE:
		if (!SvOK(key1))
			croak("Can't use undef as a key");
		RETVAL= 0;
		if ((item= TreeRBXS_get_magic_item(key1, 0))) {
			first= &item->rbnode;
			// verify it comes from this tree
			for (node= first; rbtree_node_is_in_tree(node) && node->parent; node= node->parent);
			if (node != &tree->root_sentinel)
				croak("Node is not in tree");
		}
		else {
			TreeRBXS_init_tmp_item(&stack_item, tree, key1, &PL_sv_undef);
			if (rbtree_find_all(
				&tree->root_sentinel,
				&stack_item,
				(int(*)(void*,void*,void*)) tree->compare,
				tree, -OFS_TreeRBXS_item_FIELD_rbnode,
				&first, &last, &count)
			) {
				if (key2)
					last= NULL;
			}
			else {
				// Didn't find any matches.  But if range is given, then start deleting
				// from the node following the key
				if (key2) {
					first= last;
					last= NULL;
				}
			}
		}
		// If a range is given, and the first part of the range found a node,
		// look for the end of the range.
		if (key2 && first) {
			if ((item= TreeRBXS_get_magic_item(key2, 0))) {
				last= &item->rbnode;
				// verify it comes from this tree
				for (node= last; rbtree_node_is_in_tree(node) && node->parent; node= node->parent);
				if (node != &tree->root_sentinel)
					croak("Node is not in tree");
			}
			else {
				TreeRBXS_init_tmp_item(&stack_item, tree, key2, &PL_sv_undef);
				if (rbtree_find_all(
					&tree->root_sentinel,
					&stack_item,
					(int(*)(void*,void*,void*)) tree->compare,
					tree, -OFS_TreeRBXS_item_FIELD_rbnode,
					&node, &last, NULL)
				) {
					// first..last is ready to be deleted
				} else {
					// didn't match, so 'node' holds the final element before the key
					last= node;
				}
			}
			// Ensure that first comes before last
			if (last && rbtree_node_index(first) > rbtree_node_index(last))
				last= NULL;
		}
		// Delete the nodes if constructed a successful range
		i= 0;
		if (first && last) {
			do {
				item= GET_TreeRBXS_item_FROM_rbnode(first);
				first= (first == last)? NULL : rbtree_node_next(first);
				TreeRBXS_item_detach_tree(item, tree);
				++i;
			} while (first);
		}
		RETVAL= i;
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

struct TreeRBXS_item *
root_node(tree)
	struct TreeRBXS *tree
	CODE:
		RETVAL= !tree->root_sentinel.left->count? NULL
			: GET_TreeRBXS_item_FROM_rbnode(tree->root_sentinel.left);
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

void
tree(item)
	struct TreeRBXS_item *item
	INIT:
		struct TreeRBXS *tree= TreeRBXS_item_get_tree(item);
	PPCODE:
		ST(0)= tree && tree->owner? tree->owner : &PL_sv_undef;
		XSRETURN(1);

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

struct TreeRBXS_item *
left_leaf(item)
	struct TreeRBXS_item *item
	INIT:
		rbtree_node_t *node= rbtree_node_left_leaf(&item->rbnode);
	CODE:
		RETVAL= node? GET_TreeRBXS_item_FROM_rbnode(node) : NULL;
	OUTPUT:
		RETVAL

struct TreeRBXS_item *
right_leaf(item)
	struct TreeRBXS_item *item
	INIT:
		rbtree_node_t *node= rbtree_node_right_leaf(&item->rbnode);
	CODE:
		RETVAL= node? GET_TreeRBXS_item_FROM_rbnode(node) : NULL;
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
	EXPORT_ENUM(CMP_PERL);
	EXPORT_ENUM(CMP_INT);
	EXPORT_ENUM(CMP_FLOAT);
	EXPORT_ENUM(CMP_UTF8);
	EXPORT_ENUM(CMP_MEMCMP);
	EXPORT_ENUM(CMP_NUMSPLIT);
	EXPORT_ENUM(GET_EQ);
	EXPORT_ENUM(GET_EQ_LAST);
	EXPORT_ENUM(GET_GE);
	EXPORT_ENUM(GET_LE);
	EXPORT_ENUM(GET_LE_LAST);
	EXPORT_ENUM(GET_GT);
	EXPORT_ENUM(GET_LT);
	EXPORT_ENUM(GET_NEXT);
	EXPORT_ENUM(GET_PREV);

PROTOTYPES: DISABLE
