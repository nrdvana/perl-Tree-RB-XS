#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#define AUTOCREATE 1
#define OR_DIE 2
#define KEY_TYPE_INT 1
#define KEY_TYPE_STR 2
#define KEY_TYPE_ANY 3
#define KEY_TYPE_MAX 3

struct rbtree {
	SV *owner;
	int key_type;
	CV *compare_callback;
};

void rbtree_destroy(struct rbtree *tree) {
	
}

/*------------------------------------------------------------------------------------
 * This defines the "Magic" that perl attaches to a scalar.
 */
static int rbtree_magic_free(pTHX_ SV* sv, MAGIC* mg) {
    if (mg->mg_ptr) {
        rbtree_destroy((struct rbtree*) mg->mg_ptr);
		Safefree(mg->mg_ptr);
		mg->mg_ptr= NULL;
	}
    return 0; // ignored anyway
}
#ifdef USE_ITHREADS
static int rbtree_magic_dup(pTHX_ MAGIC *mg, CLONE_PARAMS *param) {
    croak("This object cannot be shared between threads");
    return 0;
};
#else
#define rbtree_magic_dup 0
#endif
static MGVTBL rbtree_magic_vt= {
	0, /* get */
	0, /* write */
	0, /* length */
	0, /* clear */
	rbtree_magic_free,
	0, /* copy */
	rbtree_magic_dup
#ifdef MGf_LOCAL
	,0
#endif
};

/* Get rbtree struct attached to a Perl SV.
 * The sv should be the inner SV/HV/AV of the object, not an RV pointing to it.
 * Use AUTOCREATE to attach magic if it wasn't present.
 * Use OR_DIE for a built-in croak() if the return value would be NULL.
 */
static struct rbtree* rbtree_get_obj_tree(SV *sv, int create_flag) {
	MAGIC* magic;
    struct rbtree *tree;
	if (SvMAGICAL(sv)) {
        /* Iterate magic attached to this scalar, looking for one with our vtable */
        for (magic= SvMAGIC(sv); magic; magic = magic->mg_moremagic)
            if (magic->mg_type == PERL_MAGIC_ext && magic->mg_virtual == &rbtree_magic_vt)
                /* If found, the mg_ptr points to the fields structure. */
                return (struct rbtree*) magic->mg_ptr;
    }
    if (create_flag & AUTOCREATE) {
        Newxz(tree, 1, struct rbtree);
        magic= sv_magicext(sv, NULL, PERL_MAGIC_ext, &rbtree_magic_vt, (const char*) tree, 0);
#ifdef USE_ITHREADS
        magic->mg_flags |= MGf_DUP;
#endif
        return tree;
    }
    else if (create_flag == OR_DIE)
        croak("Object lacks 'struct rbtree' magic");
	return NULL;
}

MODULE = Tree::RB::XS              PACKAGE = Tree::RB::XS

void
_init_tree(obj, key_type, compare_fn= NULL)
	SV *obj
	int key_type
	CV *compare_fn
	INIT:
		struct rbtree *tree;
	CODE:
		if (!sv_isobject(obj))
			croak("_init_tree called on non-object");
		if (keytype < 0 || keytype > KEY_TYPE_MAX)
			croak("invalid key_type");
		tree= rbtree_get_obj_tree(SvRV(obj), AUTOCREATE);
		if (tree->owner)
			croak("Tree is already initialized");
		tree->owner= SvRV(obj);
		tree->key_type= key_type;
		tree->compare_callback= SvOK(compare_fn)? compare_fn : NULL;

BOOT:
	HV* stash= gv_stashpvn("Tree::RB::XS", 12, 1);
	newCONSTSUB(stash, "KEY_TYPE_INT", newSViv(KEY_TYPE_INT));
	newCONSTSUB(stash, "KEY_TYPE_STR", newSViv(KEY_TYPE_STR));
	newCONSTSUB(stash, "KEY_TYPE_ANY", newSViv(KEY_TYPE_ANY));
