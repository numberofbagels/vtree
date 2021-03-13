#!/usr/bin/env perl

use strict;
use warnings;

use Digest::MD5;
use Getopt::Long;
use Cwd 'abs_path';
use File::Basename;

my $create_root;
my $update_root;
my $compare_root;
my $validate_root;
my $help;
my $root;
my $dry_run;
my $verbose;
my $pr_stats;

my $block_hash_name = ".mrkl_block.md5";
my $chld_hash_name = ".mrkl_child.md5";

my %stats = init_stats();
$stats{'start'} = time;

GetOptions("compare=s" => \$compare_root,
           "update=s"  => \$update_root,
           "root=s"    => \$root,
           "create=s"    => \$create_root,
           "validate=s"  => \$validate_root,
           "dry-run"   => \$dry_run,
           "verbose"   => \$verbose,
           "statistics"   => \$pr_stats,
           "help"      => \$help);

usage() and exit 0 if $help;

usage("Must specify one --create, --update, --compare, or --validate!") and exit 1 if (not ($create_root or $update_root or $compare_root or $validate_root));
usage("--root must be used also!") and exit 1 if ($update_root and not $root);
usage("--root must be used also!") and exit 1 if ($compare_root and not $root);

my $exit_code = 0;

if ($create_root)
{
    my $hash = init_tree($create_root);
    if ($hash)
    {
        print "$hash\n";
    } else
    {
        $exit_code = 1;
    }
} elsif ($update_root)
{
    my $hash = update_tree($update_root, $root);
    if ($hash)
    {
        print "$hash\n";
    } else
    {
        $exit_code = 1;
    }
} elsif ($compare_root)
{
    my $diff_nodes = compare_trees($compare_root, $root);
    if ($diff_nodes == 0)
    {
        $exit_code = 1 
    } elsif (@$diff_nodes)
    {
        foreach my $node (@$diff_nodes)
        {
            print "$node\n";
        }
        
        $exit_code = 2;
    }
} else {
    my $hash = validate_tree($validate_root);
    if ($hash)
    {
        print "$hash\n";
    } else
    {
        $exit_code = 1;
    }
}

$stats{'stop'} = time;
print_stats(%stats) if $pr_stats;

exit $exit_code;

#################################################################

sub init_stats
{
    my %stats = ();
    $stats{'start'} = 0;
    $stats{'stop'} = 0;
    $stats{'dir_processed'} = 0;
    $stats{'file_processed'} = 0;
    $stats{'invalid_data_blocks'} = 0;
    $stats{'invalid_child_nodes'} = 0;

    return %stats;
}

sub print_stats
{
    my %stats = @_;

    my $duration = $stats{'stop'} - $stats{'start'};

    print STDERR "\nRuntime statistics:\n";
    print STDERR "Duration: $duration seconds\n";
    print STDERR "Directories processed: " . $stats{'dir_processed'} . "\n";
    print STDERR "Files processed: " . $stats{'file_processed'} . "\n";
    print STDERR "Invalid data blocks found: " . $stats{'invalid_data_blocks'} . "\n";
    print STDERR "Invalid child nodes found: " . $stats{'invalid_child_nodes'} . "\n";

    return 1;
}

sub validate_tree
{
    my $root_node = shift;
    my $dry_run = 1;
    my $validate_mode = 1;
    return init_tree($root_node, $validate_mode);
}

sub get_files
{
    my $dir = shift;
    my @file_list = ();
    my $dh;

    unless(opendir ($dh, $dir))
    {
        print_error("Unable to open [$dir] for reading");
        return undef;
    }

    print_verb("Getting files from [$dir]");

    foreach my $file (sort readdir($dh))
    {
        next if ($file eq "." or $file eq "..");
        next if ($file =~ /^\.mrkl_/);
        if (-l "$dir/$file")
        {
            print_verb("Found symlink [$file]") 
        } elsif (-d "$dir/$file" and not -l "$dir/$file")
        {
            print_verb("Found directory [$file]") 
        } elsif (-f "$dir/$file")
        {
            print_verb("Found file [$file]") 
        } else {
            print_verb("Found special [$file]");
        }

        push @file_list, $file;
    }

    closedir($dh);
    return \@file_list;
}

sub init_tree
{
    my ($root_node, $validate) = @_;
    my $block_hasher = Digest::MD5->new;
    my $child_hasher = Digest::MD5->new;

    return print_error("[$root_node] is not a directory") unless (-d "$root_node");

    $root_node = abs_path($root_node);
    print_verb("Initializing [$root_node]");

    my @st = stat("$root_node");
    return print_error("Unable to stat [$root_node]") unless @st;
    print_verb("Hashing [$root_node] mode [" . $st[2] . "] into data block hash");
    $block_hasher->add($st[2]);

    my $file_list = get_files("$root_node");
    return 0 unless defined $file_list;

    foreach my $file (@$file_list)
    {
        my $fullfile = "$root_node/$file";

        if (-l $fullfile)
        {
            @st = lstat("$fullfile");
            return print_error("Unable to stat symlink [$fullfile]") unless @st;
            print_verb("Hashing symlink [$file] and mode [" . $st[2] . "] into data block hash");
            $block_hasher->add("$file" . $st[2]) || return print_error("Unable to add $fullfile hash to $root_node block hash");
            $stats{'file_processed'}++;
        } elsif (-d $fullfile)
        {
            # Don't hash the mtime or mode because then it'll look like this block changed when really 
            # a subdirectory changed. We only want to know if the directory name changed.
            # mtime and mode will get pulled into that subdirectory's data block hash
            print_verb("Hashing directory name [$file] into data block hash");
            $block_hasher->add("$file");

            print_verb("$root_node -> $file");
            my $chld_node_hash = init_tree("$fullfile", $validate);
            print_verb("$root_node <- $file");

            unless ($validate)
            {
                return 0 unless $chld_node_hash;
            }

            $child_hasher->add($chld_node_hash) || return print_error("Unable to add $chld_node_hash to $root_node node hash");
        } elsif (-f $fullfile)
        {
            @st = stat("$fullfile");
            return print_error("Unable to stat [$fullfile]") unless @st;
            print_verb("Hashing filename [$file], mtime [" . $st[9] . "], and mode [" . $st[2] . "] into data block hash");
            $block_hasher->add("$file" . $st[9] . $st[2]) || return print_error("Unable to add $fullfile hash to $root_node block hash");
            $stats{'file_processed'}++;
        } else
        {
            # Like a symlink, special files don't make sense to store mtime
            @st = stat("$fullfile");
            return print_error("Unable to stat special [$fullfile]") unless @st;
            print_verb("Hashing special [$file] and mode [" . $st[2] . "] into data block hash");
            $block_hasher->add("$file" . $st[2]) || return print_error("Unable to add $fullfile hash to $root_node block hash");
            $stats{'file_processed'}++;
        }
    }

    $stats{'dir_processed'}++;

    my $block_hash = $block_hasher->hexdigest;
    $child_hasher->add($block_hash) || return print_error("Unable to add $block_hash to $root_node node hash");
    my $chld_hash = $child_hasher->hexdigest;

    my $block_hash_file = "$root_node/$block_hash_name";
    my $chld_hash_file = "$root_node/$chld_hash_name";

    if ($validate)
    {
        print_verb("Validating block and child node hash for [$root_node]");
        open(my $blk_fh, "< $block_hash_file") || return print_error("Unable to open [$block_hash_file] for reading");
        open(my $chld_fh, "< $chld_hash_file") || return print_error("Unable to open [$chld_hash_file] for reading");

        my $curr_block_hash = <$blk_fh>;
        my $curr_chld_hash = <$chld_fh>;
        chomp $curr_block_hash;
        chomp $curr_chld_hash;
        close $blk_fh;
        close $chld_fh;

        if (($curr_block_hash ne $block_hash))
        {
            $stats{'invalid_data_blocks'}++;
            print "$root_node block hash is invalid\n";
            return 0;
        } elsif (($curr_chld_hash ne $chld_hash))
        {
            $stats{'invalid_child_nodes'}++;
            print "$root_node node hash is invalid\n";
            return 0;
        }
    } else
    {
        unless ($dry_run)
        {
            print_verb("$root_node block data hash [$block_hash] child data node hash [$chld_hash]");
            open(my $blk_fh, "> $block_hash_file") || return print_error("Unable to open [$block_hash_file] for reading");
            open(my $chld_fh, "> $chld_hash_file") || return print_error("Unable to open [$chld_hash_file] for reading");

            print $blk_fh "$block_hash\n";
            print $chld_fh "$chld_hash\n";

            close $blk_fh;
            close $chld_fh;
        } else
        {
            print "$root_node block data hash: $block_hash\n";
            print "$root_node child node hash: $chld_hash\n";
        }
    }

    return $chld_hash;
}

sub get_block_hash
{
    my $dir = shift;
    my $block_hash_file = "$dir/$block_hash_name";
    open(my $fh, "< $block_hash_file") || return print_error("Unable to open $block_hash_file for reading");
    my $block_hash = <$fh>;
    close $fh;
    chomp $block_hash;
    return $block_hash;
}

sub get_node_hash
{
    my $dir = shift;

    my $chld_hash_file = "$dir/$chld_hash_name";
    open(my $fh, "< $chld_hash_file") || return print_error("Unable to open $chld_hash_file");
    my $chld_hash = <$fh>;
    close $fh;
    chomp $chld_hash;
    return $chld_hash;
}

sub update_tree
{
    my ($update_node, $root_node) = @_;

    return print_error("[$update_node] is not a directory") unless (-d "$update_node");
    return print_error("[$root_node] is not a directory") unless (-d "$root_node");

    $root_node = abs_path($root_node);
    $update_node = abs_path($update_node);

    my $chld_hash = init_tree($update_node);
    return 0 unless $chld_hash;

    my $curr_dir = $update_node;

    while ($curr_dir ne $root_node)
    {
        my $child_hasher = Digest::MD5->new;
        my $parent_dir = dirname($curr_dir);
        chdir($parent_dir) || return print_error("Unable to chdir from [$curr_dir] to [$parent_dir]");
        $curr_dir = $parent_dir;

        print_verb("Updating child node hash in $curr_dir");

        my $file_list = get_files("$curr_dir");

        foreach my $file (@$file_list)
        {
            my $fullfile = "$curr_dir/$file";
            if (-d $fullfile and not -l $fullfile)
            {
                $chld_hash = get_node_hash("$fullfile");
                return 0 unless $chld_hash;
                $child_hasher->add($chld_hash) || return print_error("Unable to add $chld_hash to $curr_dir node hash");
            }
        }

        my $block_hash = get_block_hash($curr_dir);
        return 0 unless $block_hash;

        $child_hasher->add($block_hash);
        $chld_hash = $child_hasher->hexdigest;

        unless($dry_run)
        {
            print_verb("New child node hash for $curr_dir is [$chld_hash]");

            open(my $chld_fh, "> $curr_dir/$chld_hash_name") || return print_error("Unable to open [$curr_dir/$chld_hash_name] for writing");
            print $chld_fh "$chld_hash\n";
            close $chld_fh;
        } else
        {
            print "$curr_dir child node hash is now $chld_hash\n";
        }

        $stats{'dir_processed'}++;
    }

    return $chld_hash;
}

sub compare_trees
{
    my ($local_node, $remote_node) = @_;
    my @diff_nodes = ();

    $stats{'dir_processed'}++;

    $local_node = abs_path($local_node);
    $remote_node = abs_path($remote_node);

    print_verb("Comparing $local_node to $remote_node");
    
    my $local_node_hash = get_node_hash($local_node);
    return 0 unless $local_node_hash;
    my $remote_node_hash = get_node_hash($remote_node);
    return 0 unless $remote_node_hash;

    #Is any block node in either tree different?
    print_verb("Checking if $local_node node hash matches $remote_node");
    return [] if ($local_node_hash eq $remote_node_hash);

    print_verb("$local_node node hash different than $remote_node");

    # Some block node is different. Is it this one?
    my $local_block_hash = get_block_hash($local_node);
    return 0 unless $local_block_hash;
    my $remote_block_hash = get_block_hash($remote_node);
    return 0 unless $remote_block_hash;

    if ($local_block_hash ne $remote_block_hash)
    {
        print_verb("Found $local_node block differs from $remote_node");
        return [$local_node];
    }

    print_verb("$local_node block hash matches $remote_node, searching subdirectories");

    # This is not the differing block, search subdirectories for it
    # Because this block node is the same, all directories are the same
    # in both locations.
    my $file_list = get_files("$local_node");
    foreach my $file (@$file_list)
    {
        my $fullfile = "$local_node/$file";
        if (-d $fullfile and not -l $fullfile)
        {
            print_verb("$local_node -> $file");
            my $tmp_nodes = compare_trees("$local_node/$file", "$remote_node/$file");
            print_verb("$local_node <- $file : Got " . scalar(@$tmp_nodes) . " diff nodes");
            return 0 if $tmp_nodes == 0;
            push @diff_nodes, @$tmp_nodes;
        }
    }

    return \@diff_nodes;
}

sub print_verb
{
    my $msg = shift;
    print "$msg\n" if ($msg and $verbose);
    return 1;
}

sub print_error
{
    my $msg = shift;
    print STDERR "Error: $msg\n" if $msg;
    return 0;
}

sub usage
{
    my $msg = shift;
    print "$msg\n" if $msg;

    print "Usage:\n";
    print "  vtree.pl [operation] [options]\n\n";
    print "Where:\n";
    print "  Operations, must specify one of these:\n";
    print "    --create <path>      Create validation tree rooted at <path>. Outputs new root node hash.\n";
    print "    --update <path>      Update the validation tree at subtree <path>. Requires --root also.\n";
    print "                         Updating the root node (--update is the same as --root) is the same as\n";
    print "                         --create <path>. Outputs new root node hash.\n";
    print "    --compare <path>     Compare the tree at <path> to a different tree specified with --root.\n";
    print "                         Outputs a list of nodes whose block hashes differ.\n";
    print "    --validate <path>    Validate the tree rooted at <path>. Outputs any discrepencies.\n";
    print "  Options, may need at least 1:\n";
    print "    --root <root>    The root node to use for other operations.\n";
    print "    --dry-run        Don't actually make changes, just say what would have happened.\n";
    print "    --verbose        Print out details about what's going on.\n";
    print "    --statistics     Print out statistics about the runtime to STDERR.\n";

    return 1;
}
