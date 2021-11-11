package Tree::RB::XS

# VERSION
# ABSTRACT: Similar API to Tree::RB implemented in C

use strict;
use warnings;
require XSLoader;
XSLoader::load('Tree::RB::XS', $Tree::RB::XS::VERSION);

1;
