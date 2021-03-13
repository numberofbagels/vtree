# vtree
## Overview
Uses a Merkle tree to detect when a filesystem changes. The purpose is the create an efficient way of determining when a filesystem has changed, and specifically
to compare two filesystems which are supposed to be the same to each other. The expected use case is synchronizing a large filesystem structure out to a remote
location where you would want to know when one changed so that the other could be updated. Typically one could use rsync for this purpose, but in very large
filesystems, using rsync to compute checksums to determine the differences can be expensive. This data structure can be used to determine exactly which portions 
of a filesystem have changed which allows you to target the rsync to only that sub-tree.

## Description
vtree.pl will create a Merkle tree across a filesystem root by efficiently calculating checksums for each directory (data block hash) and each sub-tree hierarchy
(child node hash). In a traditional Merkle tree, only the root of the tree contains data block hashes. In this implementation, every directory is considered a
leaf in the tree implicitly.

### Data Block Hash
Each data block has an MD5 hash for the entire directory's contents. A directory, D, may contain other directories, normal files, symbolic links, and "special" files
(e.g., sockets, block/character, etc). Hard links aren't considered. In D, an MD5 hash is computed by hashing together: the names of any subdirectories; the name,
mode, and mtime of normal files; the name and mode of symbolic links; and the name and mode of special files.

The actual contents of files don't need to be hashed, assuming that users are not making changes to the files and then updating the mtime by "touch"ing the file
afterwards. This makes generating the overall hash tree very efficient. 

The ctime can be used instead of the mtime, but be aware that the ctime can't be used to compare directory trees across filesystems since the ctime is only
consistent on the same filesystem. This should only be used for the use case where you want to determine if a change has been made in the directory structure.

### Child Node Hash
Each directory also contains an MD5 hash that rolls up all of its descendent child node hashes and its own data block hash. For a directory, D, it will compute its
child node hash by hashing together all of its subdirectories' child node hashes and its own data block hash. The full tree of child node hashes is thus computed
via a depth first search across the filesystem tree. 

## Use Cases
A directory tree T is created a location A, and rsync'd to location B. vtree.pl is used to create the Merkle tree overlay on each filesystem. Both should compute
the same root child node hash.

### Determine if a tree has changed
vtree.pl can re-calculate the Merkle tree and compare it to the existing hash values, noting any differences. This will run in O(n) time.

### Determine differences between two trees
vtree.pl can quickly identify if any part of A has changed relative to B. It does this by doing a depth first search of A and B, comparing the child node hash. If
subtree from that node has changed, then the child node hash will be different. If the data block hash at that level is the same, then those two nodes are identical
and the change is further down in the tree. As the trees are walked, any node that has a differing child node hash and data block hash indicates the root of a 
sub-tree that needs to be sync'd from A to B. The DFS returns early and continues searching. And node that has the same child node hash in A and B indicates that
no part of that sub-tree differs and the DFS can return early. That means determining differences runs in O(log n) time.

### Update a tree after a change
After sync'ing A to B, the Merkle tree on B needs to be updated. This is done with vtree.pl by re-calculating the Merkle tree rooted at the updated node, and then
recalculating the child node hash for each node between the updated node and the root. This runs in O(n) time in the worst case where the root node of the tree
is updated, but would run O(log n) on average.
