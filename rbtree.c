/* Auto-Generated by RBGen version 0.1 on 2021-10-12T14:36:27Z */

/*
Credits:

  Intrest in red/black trees was inspired by Dr. John Franco, and his animated
    red/black tree java applet.
  http://www.ececs.uc.edu/~franco/C321/html/RedBlack/redblack.html

  The node insertion code was written in a joint effort with Anthony Deeter,
    as a class project.

  The red/black deletion algorithm was derived from the deletion patterns in
   "Fundamentals of Sequential and Parallel Algorithms",
    by Dr. Kenneth A. Berman and Dr. Jerome L. Paul

  I also got the sentinel node idea from this book.

*/

#include "./rbtree.h"
#include <assert.h>

#define IS_BLACK(node)         (!(node)->color)
#define IS_RED(node)           ((node)->color)
#define NODE_IS_IN_TREE(node)  ((node)->count != 0)
#define SET_COLOR_BLACK(node)  ((node)->color= 0)
#define SET_COLOR_RED(node)    ((node)->color= 1)
#define COPY_COLOR(dest,src)   ((dest)->color= (src)->color)
#define GET_COUNT(node)        ((node)->count)
#define SET_COUNT(node,val)    ((node)->count= (val))
#define ADD_COUNT(node,val)    ((node)->count+= (val))
#define IS_SENTINEL(node)      (!(bool) (node)->count)
#define IS_ROOTSENTINEL(node)  (!(bool) (node)->parent)
#define NOT_SENTINEL(node)     ((bool) (node)->count)
#define NOT_ROOTSENTINEL(node) ((bool) (node)->parent)
#define PTR_OFS(node,ofs)      ((void*)(((char*)(void*)(node))+ofs))

static void Balance( rbtree_node_t *current );
static void RotateRight( rbtree_node_t *node );
static void RotateLeft( rbtree_node_t *node );
static void PruneLeaf( rbtree_node_t *node );
static void InsertAtLeaf( rbtree_node_t *leaf, rbtree_node_t *new_node, bool on_left);

void rbtree_init_tree( rbtree_node_t *root_sentinel, rbtree_node_t *leaf_sentinel ) {
	SET_COUNT(root_sentinel, 0);
	SET_COLOR_BLACK(leaf_sentinel);
	root_sentinel->parent= NULL;
	root_sentinel->left= leaf_sentinel;
	root_sentinel->right= leaf_sentinel;
	SET_COUNT(leaf_sentinel, 0);
	SET_COLOR_BLACK(leaf_sentinel);
	leaf_sentinel->left= leaf_sentinel;
	leaf_sentinel->right= leaf_sentinel;
	leaf_sentinel->parent= leaf_sentinel;
}

rbtree_node_t *rbtree_node_left_leaf( rbtree_node_t *node ) {
	if (IS_SENTINEL(node)) return NULL;
	while (NOT_SENTINEL(node->left))
		node= node->left;
	return node;
}

rbtree_node_t *rbtree_node_right_leaf( rbtree_node_t *node ) {
	if (IS_SENTINEL(node)) return NULL;
	while (NOT_SENTINEL(node->right))
		node= node->right;
	return node;
}

rbtree_node_t *rbtree_node_prev( rbtree_node_t *node ) {
	if (IS_SENTINEL(node)) return NULL;
	// If we are not at a leaf, move to the right-most node
	//  in the tree to the left of this node.
	if (NOT_SENTINEL(node->left)) {
		node= node->left;
		while (NOT_SENTINEL(node->right))
			node= node->right;
		return node;
	}
	// Else walk up the tree until we see a parent node to the left
	else {
		rbtree_node_t *parent= node->parent;
		while (parent->left == node) {
			node= parent;
			parent= parent->parent;
			// Check for root_sentinel
			if (!parent) return NULL;
		}
		return parent;
	}
}

rbtree_node_t *rbtree_node_next( rbtree_node_t *node ) {
	if (IS_SENTINEL(node)) return NULL;
	// If we are not at a leaf, move to the left-most node
	//  in the tree to the right of this node.
	if (NOT_SENTINEL(node->right)) {
		node= node->right;
		while (NOT_SENTINEL(node->left))
			node= node->left;
		return node;
	}
	// Else walk up the tree until we see a parent node to the right
	else {
		rbtree_node_t *parent= node->parent;
		assert(parent);
		while (parent->right == node) {
			assert(parent != parent->parent);
			node= parent;
			parent= node->parent;
		}
		// Check for the root_sentinel
		if (!parent->parent) return NULL;
		return parent;
	}
}

/** Simple find algorithm.
 * This function looks for the nearest node to the requested key, returning the node and
 * the final value of the compare function which indicates whether this is the node equal to,
 * before, or after the requested key.
 */
rbtree_node_t * rbtree_find_nearest(rbtree_node_t *node, void *goal,
	int(*compare)(void *ctx, void *a,void *b), void *ctx, int cmp_ptr_ofs,
	int *last_cmp_out
) {
	rbtree_node_t *nearest= NULL, *test;
	int count, cmp= 0;
	
	if (IS_ROOTSENTINEL(node))
		node= node->left;

	while (NOT_SENTINEL(node)) {
		nearest= node;
		cmp= compare( ctx, goal, PTR_OFS(node,cmp_ptr_ofs) );
		if      (cmp<0) node= node->left;
		else if (cmp>0) node= node->right;
		else break;
	}
	if (nearest && last_cmp_out)
		*last_cmp_out= cmp;
	return nearest;
}

/** Find-all algorithm.
 * This function not only finds a node, but can find the nearest node to the one requested, finds the number of
 * matching nodes, and gets the first and last node so the matches can be iterated.
 */
bool rbtree_find_all(rbtree_node_t *node, void* goal,
	int(*compare)(void *ctx, void *a,void *b), void *ctx, int cmp_ptr_ofs,
	rbtree_node_t **result_first, rbtree_node_t **result_last, size_t *result_count
) {
	rbtree_node_t *nearest= NULL, *first, *last, *test;
	size_t count;
	int cmp;
	
	if (IS_ROOTSENTINEL(node))
		node= node->left;

	while (NOT_SENTINEL(node)) {
		nearest= node;
		cmp= compare( ctx, goal, PTR_OFS(node,cmp_ptr_ofs) );
		if      (cmp<0) node= node->left;
		else if (cmp>0) node= node->right;
		else break;
	}
	if (IS_SENTINEL(node)) {
		/* no matches. Look up neighbor node if requested. */
		if (result_first)
			*result_first= nearest && cmp < 0? rbtree_node_prev(nearest) : nearest;
		if (result_last)
			*result_last=  nearest && cmp > 0? rbtree_node_next(nearest) : nearest;
		if (result_count) *result_count= 0;
		return false;
	}
	// we've found the head of the tree the matches will be found in
	count= 1;
	if (result_first || result_count) {
		// Search the left tree for the first match
		first= node;
		test= first->left;
		while (NOT_SENTINEL(test)) {
			cmp= compare( ctx, goal, PTR_OFS(test,cmp_ptr_ofs) );
			if (cmp == 0) {
				first= test;
				count+= 1 + GET_COUNT(test->right);
				test= test->left;
			}
			else /* cmp > 0 */
				test= test->right;
		}
		if (result_first) *result_first= first;
	}
	if (result_last || result_count) {
		// Search the right tree for the last match
		last= node;
		test= last->right;
		while (NOT_SENTINEL(test)) {
			cmp= compare( ctx, goal, PTR_OFS(test,cmp_ptr_ofs) );
			if (cmp == 0) {
				last= test;
				count+= 1 + GET_COUNT(test->left);
				test= test->right;
			}
			else /* cmp < 0 */
				test= test->left;
		}
		if (result_last) *result_last= last;
		if (result_count) *result_count= count;
	}
	return true;
}

/* Insert a new object into the tree.  The initial node is called 'hint' because if the new node
 * isn't a child of hint, this will backtrack up the tree to find the actual insertion point.
 */
bool rbtree_node_insert( rbtree_node_t *hint, rbtree_node_t *node, int(*compare)(void *ctx, void *a, void *b), void *ctx, int cmp_ptr_ofs) {
	// Can't insert node if it is already in the tree
	if (NODE_IS_IN_TREE(node))
		return false;
	// check for first node scenario
	if (IS_ROOTSENTINEL(hint)) {
		if (IS_SENTINEL(hint->left)) {
			hint->left= node;
			node->parent= hint;
			node->left= hint->right; // tree's leaf sentinel
			node->right= hint->right;
			SET_COUNT(node, 1);
			SET_COLOR_BLACK(node);
			return true;
		}
		else
			hint= hint->left;
	}
	// else traverse hint until leaf
	int cmp;
	bool leftmost= true, rightmost= true;
	rbtree_node_t *pos= hint, *next, *parent;
	while (1) {
		cmp= compare(ctx, PTR_OFS(node,cmp_ptr_ofs), PTR_OFS(pos,cmp_ptr_ofs) );
		if (cmp < 0) {
			rightmost= false;
			next= pos->left;
		} else {
			leftmost= false;
			next= pos->right;
		}
		if (IS_SENTINEL(next))
			break;
		pos= next;
	}
	// If the original hint was not the root of the tree, and cmp indicate the same direction 
	// as leftmost or rightmost, then backtrack and see if we're completely in the wrong spot.
	if (NOT_ROOTSENTINEL(hint->parent) && (cmp < 0? leftmost : rightmost)) {
		// we are the leftmost child of hint, so if there is a parent to the left,
		// key needs to not compare less else we have to start over.
		parent= hint->parent;
		while (1) {
			if ((cmp < 0? parent->right : parent->left) == hint) {
				if ((cmp < 0) == (compare(ctx, PTR_OFS(node,cmp_ptr_ofs), PTR_OFS(parent,cmp_ptr_ofs)) < 0)) {
					// Whoops.  Hint was wrong.  Should start over from root.
					while (NOT_ROOTSENTINEL(parent->parent))
						parent= parent->parent;
					return rbtree_node_insert(parent, node, compare, ctx, cmp_ptr_ofs);
				}
				else break; // we're fine afterall
			}
			else if (IS_ROOTSENTINEL(parent->parent))
				break; // we're fine afterall
			parent= parent->parent;
		}
	}
	if (cmp < 0)
		pos->left= node;
	else
		pos->right= node;
	node->parent= pos;
	// next is pointing to the leaf-sentinel for this tree after exiting loop above
	node->left= next;
	node->right= next;
	SET_COUNT(node, 1);
	SET_COLOR_RED(node);
	for (parent= pos; NOT_ROOTSENTINEL(parent); parent= parent->parent)
		ADD_COUNT(parent, 1);
	Balance(pos);
	// We've iterated to the root sentinel- so node->left is the head of the tree.
	// Set the tree's root to black
	SET_COLOR_BLACK(parent->left);
	return true;
}

void RotateRight( rbtree_node_t *node ) {
	rbtree_node_t *new_head= node->left;
	rbtree_node_t *parent= node->parent;

	if (parent->right == node) parent->right= new_head;
	else parent->left= new_head;
	new_head->parent= parent;

	ADD_COUNT(node, -1 - GET_COUNT(new_head->left));
	ADD_COUNT(new_head, 1 + GET_COUNT(node->right));
	node->left= new_head->right;
	new_head->right->parent= node;

	new_head->right= node;
	node->parent= new_head;
}

void RotateLeft( rbtree_node_t *node ) {
	rbtree_node_t *new_head= node->right;
	rbtree_node_t *parent= node->parent;

	if (parent->right == node) parent->right= new_head;
	else parent->left= new_head;
	new_head->parent= parent;

	ADD_COUNT(node, -1 - GET_COUNT(new_head->right));
	ADD_COUNT(new_head, 1 + GET_COUNT(node->left));
	node->right= new_head->left;
	new_head->left->parent= node;

	new_head->left= node;
	node->parent= new_head;
}

/** Re-balance a tree which has just had one element added.
 * current is the parent node of the node just added.  The child is red.
 *
 * node counts are *not* updated by this method.
 */
void Balance( rbtree_node_t *current ) {
	// if current is a black node, no rotations needed
	while (IS_RED(current)) {
		// current is red, the imbalanced child is red, and parent is black.

		rbtree_node_t *parent= current->parent;

		// if the current is on the right of the parent, the parent is to the left
		if (parent->right == current) {
			// if the sibling is also red, we can pull down the color black from the parent
			if (IS_RED(parent->left)) {
				SET_COLOR_BLACK(parent->left);
				SET_COLOR_BLACK(current);
				SET_COLOR_RED(parent);
				// jump twice up the tree. if current reaches the HeadSentinel (black node), the loop will stop
				current= parent->parent;
				continue;
			}
			// if the imbalance (red node) is on the left, and the parent is on the left,
			//  a "prep-slide" is needed. (see diagram)
			if (IS_RED(current->left))
				RotateRight( current );

			// Now we can do our left rotation to balance the tree.
			RotateLeft( parent );
			SET_COLOR_RED(parent);
			SET_COLOR_BLACK(parent->parent);
			return;
		}
		// else the parent is to the right
		else {
			// if the sibling is also red, we can pull down the color black from the parent
			if (IS_RED(parent->right)) {
				SET_COLOR_BLACK(parent->right);
				SET_COLOR_BLACK(current);
				SET_COLOR_RED(parent);
				// jump twice up the tree. if current reaches the HeadSentinel (black node), the loop will stop
				current= parent->parent;
				continue;
			}
			// if the imbalance (red node) is on the right, and the parent is on the right,
			//  a "prep-slide" is needed. (see diagram)
			if (IS_RED(current->right))
				RotateLeft( current );

			// Now we can do our right rotation to balance the tree.
			RotateRight( parent );
			SET_COLOR_RED(parent);
			SET_COLOR_BLACK(parent->parent);
			return;
		}
	}
	// note that we should now set the root node to be black.
	// but the caller does this anyway.
	return;
}


size_t rbtree_node_index( rbtree_node_t *node ) {
	int left_count= GET_COUNT(node->left);
	rbtree_node_t *prev= node;
	node= node->parent;
	while (NOT_SENTINEL(node)) {
		if (node->right == prev)
			left_count += GET_COUNT(node->left)+1;
		prev= node;
		node= node->parent;
	}
	return left_count;
}

/** Find the Nth node in the tree, indexed from 0, from the left to right.
 * This operates by looking at the count of the left subtree, to descend down to the Nth element.
 */
rbtree_node_t *rbtree_node_child_at_index( rbtree_node_t *node, size_t index ) {
	if (index >= GET_COUNT(node))
		return NULL;
	while (index != GET_COUNT(node->left)) {
		if (index < GET_COUNT(node->left))
			node= node->left;
		else {
			index -= GET_COUNT(node->left)+1;
			node= node->right;
		}
	}
	return node;
}

/** Prune a node from anywhere in the tree.
 * If the node is a leaf, it can be removed easily.  Otherwise we must swap the node for a leaf node
 * with an adjacent key value, and then remove from the position of that leaf.
 *
 * This function *does* update node counts.
 */
void rbtree_node_prune( rbtree_node_t *current ) {
	rbtree_node_t *temp, *successor;
	if (GET_COUNT(current) == 0)
		return;

	// If this is a leaf node (or almost a leaf) we can just prune it
	if (IS_SENTINEL(current->left) || IS_SENTINEL(current->right))
		PruneLeaf(current);

	// Otherwise we need a successor.  We are guaranteed to have one because
	//  the current node has 2 children.
	else {
		// pick from the largest subtree
		successor= (GET_COUNT(current->left) > GET_COUNT(current->right))?
			rbtree_node_prev( current )
			: rbtree_node_next( current );
		PruneLeaf( successor );

		// now exchange the successor for the current node
		temp= current->right;
		successor->right= temp;
		temp->parent= successor;

		temp= current->left;
		successor->left= temp;
		temp->parent= successor;

		temp= current->parent;
		successor->parent= temp;
		if (temp->left == current) temp->left= successor; else temp->right= successor;
		COPY_COLOR(successor, current);
		SET_COUNT(successor, GET_COUNT(current));
	}
	current->left= current->right= current->parent= NULL;
	SET_COLOR_BLACK(current);
	SET_COUNT(current, 0);
}

/** PruneLeaf performs pruning of nodes with at most one child node.
 * This is the real heart of node deletion.
 * The first operation is to decrease the node count from node to root_sentinel.
 */
void PruneLeaf( rbtree_node_t *node ) {
	rbtree_node_t *parent= node->parent, *current, *sibling, *sentinel;
	bool leftside= (parent->left == node);
	sentinel= IS_SENTINEL(node->left)? node->left : node->right;
	
	// first, decrement the count from here to root_sentinel
	for (current= node; NOT_ROOTSENTINEL(current); current= current->parent)
		ADD_COUNT(current, -1);

	// if the node is red and has at most one child, then it has no child.
	// Prune it.
	if (IS_RED(node)) {
		if (leftside) parent->left= sentinel;
		else parent->right= sentinel;
		return;
	}

	// node is black here.  If it has a child, the child will be red.
	if (node->left != sentinel) {
		// swap with child
		SET_COLOR_BLACK(node->left);
		node->left->parent= parent;
		if (leftside) parent->left= node->left;
		else parent->right= node->left;
		return;
	}
	if (node->right != sentinel) {
		// swap with child
		SET_COLOR_BLACK(node->right);
		node->right->parent= parent;
		if (leftside) parent->left= node->right;
		else parent->right= node->right;
		return;
	}

	// Now, we have determined that node is a black leaf node with no children.
	// The tree must have the same number of black nodes along any path from root
	// to leaf.  We want to remove a black node, disrupting the number of black
	// nodes along the path from the root to the current leaf.  To correct this,
	// we must either shorten all other paths, or add a black node to the current
	// path.  Then we can freely remove our black leaf.
	// 
	// While we are pointing to it, we will go ahead and delete the leaf and
	// replace it with the sentinel (which is also black, so it won't affect
	// the algorithm).

	if (leftside) parent->left= sentinel; else parent->right= sentinel;

	sibling= (leftside)? parent->right : parent->left;
	current= node;

	// Loop until the current node is red, or until we get to the root node.
	// (The root node's parent is the root_sentinel, which will have a NULL parent.)
	while (IS_BLACK(current) && NOT_ROOTSENTINEL(parent)) {
		// If the sibling is red, we are unable to reduce the number of black
		//  nodes in the sibling tree, and we can't increase the number of black
		//  nodes in our tree..  Thus we must do a rotation from the sibling
		//  tree to our tree to give us some extra (red) nodes to play with.
		// This is Case 1 from the text
		if (IS_RED(sibling)) {
			SET_COLOR_RED(parent);
			SET_COLOR_BLACK(sibling);
			if (leftside) {
				RotateLeft(parent);
				sibling= parent->right;
			}
			else {
				RotateRight(parent);
				sibling= parent->left;
			}
			continue;
		}
		// sibling will be black here

		// If the sibling is black and both children are black, we have to
		//  reduce the black node count in the sibling's tree to match ours.
		// This is Case 2a from the text.
		if (IS_BLACK(sibling->right) && IS_BLACK(sibling->left)) {
			assert(NOT_SENTINEL(sibling));
			SET_COLOR_RED(sibling);
			// Now we move one level up the tree to continue fixing the
			// other branches.
			current= parent;
			parent= current->parent;
			leftside= (parent->left == current);
			sibling= (leftside)? parent->right : parent->left;
			continue;
		}
		// sibling will be black with 1 or 2 red children here

		// << Case 2b is handled by the while loop. >>

		// If one of the sibling's children are red, we again can't make the
		//  sibling red to balance the tree at the parent, so we have to do a
		//  rotation.  If the "near" nephew is red and the "far" nephew is
		//  black, we need to rotate that tree rightward before rotating the
		//  parent leftward.
		// After doing a rotation and rearranging a few colors, the effect is
		//  that we maintain the same number of black nodes per path on the far
		//  side of the parent, and we gain a black node on the current side,
		//  so we are done.
		// This is Case 4 from the text. (Case 3 is the double rotation)
		if (leftside) {
			if (IS_BLACK(sibling->right)) { // Case 3 from the text
				RotateRight( sibling );
				sibling= parent->right;
			}
			// now Case 4 from the text
			SET_COLOR_BLACK(sibling->right);
			assert(NOT_SENTINEL(sibling));
			COPY_COLOR(sibling, parent);
			SET_COLOR_BLACK(parent);

			current= parent;
			parent= current->parent;
			RotateLeft( current );
			return;
		}
		else {
			if (IS_BLACK(sibling->left)) { // Case 3 from the text
				RotateLeft( sibling );
				sibling= parent->left;
			}
			// now Case 4 from the text
			SET_COLOR_BLACK(sibling->left);
			assert(NOT_SENTINEL(sibling));
			COPY_COLOR(sibling, parent);
			SET_COLOR_BLACK(parent);

			current= parent;
			parent= current->parent;
			RotateRight( current );
			return;
		}
	}

	// Now, make the current node black (to fulfill Case 2b)
	// Case 4 will have exited directly out of the function.
	// If we stopped because we reached the top of the tree,
	//   the head is black anyway so don't worry about it.
	SET_COLOR_BLACK(current);
}

/** Mark all nodes as being not-in-tree, and possibly delete the objects that contain them.
 * DeleteProc is optional.  If given, it will be called on the 'Object' which contains the rbtree_node_t.
 * obj_ofs is a negative (or zero) number of bytes offset from the rbtree_node_t pointer to the containing
 * object pointer.  `ctx` is a user-defined context pointer to pass to the destructor.
 */
void rbtree_clear( rbtree_node_t *root_sentinel, void (*destructor)(void *obj, void *ctx), int obj_ofs, void *ctx ) {
	rbtree_node_t *current, *next;
	int from_left;
	// Delete in a depth-first post-traversal, because the node might not exist after
	// calling the destructor.
	if (!IS_ROOTSENTINEL(root_sentinel))
		return; /* this is API usage bug, but no way to report it */
	if (IS_SENTINEL(root_sentinel->left))
		return; /* tree already empty */
	current= root_sentinel->left;
	while (1) {
		check_left: // came from above, go down-left
			if (NOT_SENTINEL(current->left)) {
				current= current->left;
				goto check_left;
			}
		check_right: // came up from the left, go down-right
			if (NOT_SENTINEL(current->right)) {
				current= current->right;
				goto check_left;
			}
		zap_current: // came up from the right, kill the current node and proceed up
			next= current->parent;
			from_left= (next->left == current)? 1 : 0;
			SET_COUNT(current, 0);
			current->left= current->right= current->parent= NULL;
			if (destructor) destructor(PTR_OFS(current,obj_ofs), ctx);
			current= next;
			if (current == root_sentinel)
				break;
			else if (from_left)
				goto check_right;
			else
				goto zap_current;
	}
	root_sentinel->left= root_sentinel->right;
	SET_COLOR_BLACK(root_sentinel);
	SET_COUNT(root_sentinel, 0);
}


static int CheckSubtree(rbtree_node_t *node, rbtree_compare_fn, void *ctx, int, int *);

int rbtree_check_structure(rbtree_node_t *node, rbtree_compare_fn compare, void *ctx, int cmp_pointer_ofs) {
	// If at root, check for root sentinel details
	if (node && !node->parent) {
		if (IS_RED(node) || IS_RED(node->left) || GET_COUNT(node) || GET_COUNT(node->right))
			return RBTREE_INVALID_ROOT;
		if (GET_COUNT(node->right) || IS_RED(node->right) || node->right->left != node->right
			|| node->right->right != node->right)
			return RBTREE_INVALID_SENTINEL;
		if (node->left == node->right) return 0; /* empty tree, nothing more to check */
		if (node->left->parent != node)
			return RBTREE_INVALID_ROOT;
		node= node->left; /* else start checking at first real node */
	}
	int black_count;
	return CheckSubtree(node, compare, ctx, cmp_pointer_ofs, &black_count);
}

int CheckSubtree(rbtree_node_t *node, rbtree_compare_fn compare, void *ctx, int cmp_pointer_ofs, int *black_count) {
	// This node should be fully attached to the tree
	if (!node || !node->parent || !node->left || !node->right || !GET_COUNT(node))
		return RBTREE_INVALID_NODE;
	// Check counts.  This is an easy way to validate the relation to sentinels too
	if (GET_COUNT(node) != GET_COUNT(node->left) + GET_COUNT(node->right) + 1)
		return RBTREE_INVALID_COUNT;
	// Check node key order
	int left_black_count= 0, right_black_count= 0;
	if (NOT_SENTINEL(node->left)) {
		if (node->left->parent != node)
			return RBTREE_INVALID_NODE;
		if (IS_RED(node) && IS_RED(node->left))
			return RBTREE_INVALID_COLOR;
		if (compare(ctx, PTR_OFS(node->left, cmp_pointer_ofs), PTR_OFS(node, cmp_pointer_ofs)) > 0)
			return RBTREE_INVALID_ORDER;
		int err= CheckSubtree(node->left, compare, ctx, cmp_pointer_ofs, &left_black_count);
		if (err) return err;
	}
	if (NOT_SENTINEL(node->right)) {
		if (node->right->parent != node)
			return RBTREE_INVALID_NODE;
		if (IS_RED(node) && IS_RED(node->right))
			return RBTREE_INVALID_COLOR;
		if (compare(ctx, PTR_OFS(node->right, cmp_pointer_ofs), PTR_OFS(node, cmp_pointer_ofs)) < 0)
			return RBTREE_INVALID_ORDER;
		int err= CheckSubtree(node->right, compare, ctx, cmp_pointer_ofs, &right_black_count);
		if (err) return err;
	}
	if (left_black_count != right_black_count)
		return RBTREE_INVALID_COLOR;
	*black_count= left_black_count + (IS_BLACK(node)? 1 : 0);
	return 0;
}
