#!/usr/bin/perl -w

use strict;
use warnings;

# we use indented HEREDOCs among other things
# so require a minimum Perl version
use 5.026;

use lib qw(
    .
    local/lib/perl5
    local/lib/perl5/x86_64-linux-thread-multi
);

#use cPanelUserConfig; # finds modules installed by Cpanel
use CGI;
use CGI::Carp('fatalsToBrowser');
use Data::Dumper;
use DBI;
use FindBin;
use HTML::Template;
use JSON;

# batteries not included,
# but this module expected at the level above (..)
# Comment this out if you need to, which you will.
# This adds the feature or sending crash reports to the screen
# and to email.
use FatalsToEmail qw(
    Mailhost localhost
    Address marcus@mindmined.com
    Error_cache /tmp/comics.tmp
    Seconds 60
    Debug 1
);

=head1 collect

Web app to archive collectibles, originally comic books.

NOTE: no web authentication or authorization is built into this code, therefore it is best to run behind something like Apache Basic Authentication.  This software is not really intended for distribution.

=cut

=head2 main

Get credentials, connect to the database, and run the requested or default action.

=cut

open DB, "$FindBin::Bin/.db" || die("Couldn't open file: $!");
open DB_HOST, "$FindBin::Bin/.dbhost" || die("Couldn't open file: $!");
open DB_USER, "$FindBin::Bin/.dbuser" || die("Couldn't open file: $!");
open DB_PASSWORD, "$FindBin::Bin/.dbpass" || die("Couldn't open file: $!");

my $DATABASE = <DB>; chomp($DATABASE);
my $DATABASE_HOST = <DB_HOST>; chomp($DATABASE_HOST);
my $DB_USER = <DB_USER>; chomp($DB_USER);
my $DB_PASSWORD = <DB_PASSWORD>; chomp($DB_PASSWORD);

my $cgi = new CGI;

print STDERR "$DATABASE, $DATABASE_HOST, $DB_USER, $DB_PASSWORD\n";

my $dsn = "DBI:mysql:database=$DATABASE;host=$DATABASE_HOST";
my $dbh = DBI->connect(
    $dsn,
    "$DB_USER",
    "$DB_PASSWORD", {
        RaiseError => 1,  # dies on errors
    }
) || die "Connect failed: $DBI::errstr\n"; 

my $action=$cgi->param('action');
$action = qq {mainInterface} if ! $action;

# run the sub by the same name as $action
# TODO: replace with a dispatch table
&{\&{$action}}();
exit;

=head2 collectionInterface()

Image-less view of all issues in the collection, or the "text index".

=cut

sub collectionInterface {
    my $message = $_[0];
    my $t = HTML::Template->new(filename => 'templates/collectionInterface.tmpl');
    my $select = <<~"SQL";
    SELECT title, id FROM comics_titles ORDER BY title
    SQL
    my $sth = $dbh->prepare($select) || die "prepare: $select: $DBI::errstr";
    $sth->execute || die "execute: $select: $DBI::errstr";
    my @titles;
    while (my ($title, $title_id) = $sth->fetchrow_array()) {
        my %row;
        $row{TITLE} = $title;
        $row{TITLE_ID} = $title_id;
        # NOTE: speed this up with a single SQL query, no inner loop
        my $select = <<~"SQL";
        SELECT id, issue_num, image_page_url 
        FROM comics WHERE title_id = ? ORDER BY issue_num
        SQL
        my $sth = $dbh->prepare($select) || die "prepare: $select: $DBI::errstr";
        $sth->execute($title_id) || die "execute: $select: $DBI::errstr";
        my @issues;
        while (my ($id, $issue_num, $image_page_url) = $sth->fetchrow_array()) {
            my %row;
            $row{ID} = $id;
            $row{ISSUE_NUM} = $issue_num;
            # $row{IMAGE_PAGE_URL} = $image_page_url;
            push(@issues, \%row);
        }
        $row{ISSUES} = \@issues;
        next unless scalar @issues;
        push(@titles, \%row);
    }
    $t->param(INDEXED_TITLES => \@titles);
    $t = _getTitlesDropdown(
        template       => $t,
    );
    my $average_year = _getAverageYear();
    my $average_grade = _getAverageGrade();
    $t->param(AVERAGE_YEAR => $average_year);
    $t->param(AVERAGE_GRADE => $average_grade);
    my $total_collection_count = _getTotalCollectionCount();
    $t->param(TOTAL_COLLECTION_COUNT => $total_collection_count);
    $t->param(MESSAGE => $message);
    my $output = $t->output;
    print "Content-type: text/html\n\n";
    print $output;
}

=head2 deleteImage

Delete an image, given its id.

=cut

sub deleteImage {
    my $id = $cgi->param('id');
    my $item_id = $cgi->param('item_id');
    # item
    my $sql = <<~"SQL";
    SELECT * FROM comics WHERE id = ?
    SQL
    my $issue_ref = $dbh->selectrow_hashref($sql, undef, $item_id);
    # image
    my $sql = <<~"SQL";
    SELECT * FROM comics_images WHERE id = ?
    SQL
    my $image_ref = $dbh->selectrow_hashref($sql, undef, $id);
    # delete
    my $delete = <<~"SQL";
    DELETE FROM comics_images WHERE id = ?
    SQL
    my $sth = $dbh->prepare($delete);
    $sth->execute($id);
    # delete file
    my $file = "${id}\.$image_ref->{extension}";
    if ( -e "$ENV{DOCUMENT_ROOT}/images/$file" ) {
        if ( unlink "$ENV{DOCUMENT_ROOT}/images/$file" ) {
            #print STDOUT "File '$file' deleted successfully.\n";
        } 
        else {
            print STDERR "Failed to delete '$file': $!\n";
        }
    }
    else {
        print STDERR "'$file' does not exist.\n";
    }
    my $message = qq |Image deleted.|;
    editIssue($item_id, $issue_ref->{title_id});
}

=head2 deleteIssue

Delete an issue, given its id.

Because we also have a Flickr page for the issue, send ourselves an email to remind us to delete the Flickr page manually, which cannot be easily done from here.

=cut

sub deleteIssue {
    my $id = $cgi->param('id');
    my $sql = <<~"SQL";
    SELECT * FROM comics WHERE id = ?
    SQL
    my $item_ref = $dbh->selectrow_hashref($sql, undef, $id);
    # delete item
    my $delete = <<~"SQL";
    DELETE FROM comics WHERE id = ?
    SQL
    my $sth = $dbh->prepare($delete);
    $sth->execute($id);
    # loop through images and delete files
    my $select = <<~"SQL";
    SELECT id FROM comics_images 
    WHERE item_id = ?
    SQL
    my $sth = $dbh->prepare($select);
    $sth->execute($id);
    while (my ($image_id, $extension) = $sth->fetchrow_array()) {
        my $filepath = "$ENV{DOCUMENT_ROOT}/images/${image_id}.${extension}";
        if ( -e $filepath ) {
            if ( unlink $filepath ) {
                #print STDOUT "File '$filepath' deleted successfully.\n";
            } 
            else {
                print STDERR "Failed to delete '$filepath': $!\n";
            }
        }
        else {
            print STDERR "'$filepath' does not exist.\n";
        }
    }
    # delete images
    $delete = <<~"SQL";
    DELETE FROM comics_images WHERE item_id = ?
    SQL
    $sth = $dbh->prepare($delete);
    $sth->execute($id);
    my $message = qq |Item deleted.|;
    mainInterface( 
        message  => $message, 
        title_id => $item_ref->{title_id}, 
    );
}

=head2 editCategory()

Screen on which to edit a category /title.

=cut

sub editCategory {
    my $id = $cgi->param('id');
    my $t = HTML::Template->new(filename => 'templates/editCategory.tmpl');
    my $sql = <<~"SQL";
    SELECT * FROM comics_titles WHERE id = ?
    SQL
    my $cat_ref = $dbh->selectrow_hashref($sql, undef, $id);
    $t->param(CATEGORY => $cat_ref->{title});
    $t->param(ID => $id);
    $t->param(SCRIPT_NAME => $ENV{SCRIPT_NAME});
    print "Content-type: text/html\n\n";
    print $t->output;
}

=head2 editIssue()

Screen on which to edit an issue record.

=cut

sub editIssue {
    my $id = $_[0] || $cgi->param('id');
    my $title_id = $_[1] || $cgi->param('title_id') || '';
    my $t = HTML::Template->new(filename => 'templates/editItem.tmpl');
    my $sql = <<~"SQL";
    SELECT * FROM comics WHERE id = ?
    SQL
    my $issue_ref = $dbh->selectrow_hashref($sql, undef, $id);
    $t = _getTitlesDropdown(
        template => $t,
        selected_title_id => $title_id || $issue_ref->{title_id},
    );
    $t = _getGradesDropdown(
        template => $t,
        selected_grade_id => $issue_ref->{grade_id},
    );
    $t->param(ISSUE_NUM => $issue_ref->{issue_num});
    # override database value if new filesystem
    # method is being used
    $t->param(YEAR => $issue_ref->{year});
    # my $localcover = "$ENV{DOCUMENT_ROOT}/images/${id}.jpg";
    # if ( -e $localcover ) {
    #     $issue_ref->{thumb_url} = "/images/${id}.jpg";
    # }
    # show all images
    my $select = <<~"SQL";
    SELECT id, extension, main, notes, stock
    FROM comics_images
    WHERE item_id = ?
    SQL
    my $sth = $dbh->prepare($select);
    $sth->execute($id);
    my @images; my %images;
    my $main_image_filename = '';
    while (my ($image_id, $extension, $main, $notes, $stock) = $sth->fetchrow_array()) {
        my %row;
        $row{NOTES} = $notes;
        $row{ID} = $image_id;
        my $filename = "${image_id}.${extension}";
        $row{FILENAME} = $filename;
        if ( $main ) {
            $main_image_filename = "${image_id}.${extension}";
        }
        else {
            $main = 0;
        }
        my $path = "$ENV{DOCUMENT_ROOT}/images";
        my $size_kb = -s "$path/$filename" ? int( ( -s "$path/$filename" ) / 1024 ) : 0;
        $row{MAIN} = $main;
        $row{STOCK} = $stock;
        $row{SIZE_KB} = $size_kb;
        push(@images, \%row);
        $images{$image_id} = {
            notes    => $notes,
            filename => $filename,
            main     => $main,
            stock    => $stock,
        };
    }
    $t->param(IMAGES => \@images);
    $t->param(IMAGES_JSON => to_json(\%images));
    $t->param(MAIN_IMAGE_FILENAME => $main_image_filename);
    $t->param(THUMB_URL => $issue_ref->{thumb_url});           # NOTE: deprecated
    $t->param(IMAGE_PAGE_URL => $issue_ref->{image_page_url}); # NOTE: deprecated
    $t->param(NOTES => $issue_ref->{notes});
    $t->param(ID => $id);
    $t->param(SCRIPT_NAME => $ENV{SCRIPT_NAME});
    print "Content-type: text/html\n\n";
    print $t->output;
}

=head2 findMissing()

Given an array of integers (issues, card numbers, etc.) return an array of integers missing in that sequence.

=cut

sub findMissing {
    my @input = @_;
    return () if scalar @input == 0;
    @input = sort { $a <=> $b } @input;
    my $min = $input[0];
    my $max = $input[-1];
    my %input_hash = map { $_ => 1 } @input;
    my @missing;
    foreach my $i ($min .. $max) {
        push @missing, $i unless exists $input_hash{$i};
    }
    return @missing;
}

=head2 mainInterface

The main image-based view of the collection, in a grid.

=cut

sub mainInterface {
    my %arg = @_;
    my $message = $arg{message};
    my $title_id = $arg{title_id};
    $title_id = $cgi->param('title_id') unless $title_id;
    my $year=$cgi->param('year');
    my $t = HTML::Template->new(
        filename => 'templates/mainInterface.tmpl',
    );
    my @where_conditions;
    my $limit = 200;
    if ( $year ) {
        push(@where_conditions, "year = '$year'");
    }
    if ( $title_id ) {
        push(@where_conditions, "item.title_id = '$title_id'");
    } 
    my $where = "WHERE" if @where_conditions; 
    my $i = 0;
    foreach my $where_condition ( @where_conditions ) {
        $i++;
        if ( $i == 1 ) {
            $where .= " $where_condition";
        }
        else {
            $where .= " AND $where_condition";
        }
    }
    my $title = '';
    if ( $title_id ) {
        my $select = <<~"SQL";
        SELECT title FROM comics_titles WHERE id = ?
        SQL
        my $sth = $dbh->prepare($select);
        $sth->execute($title_id);
        ($title) = $sth->fetchrow_array();
    }
    # get year list
    my $select = <<~"SQL";
    SELECT DISTINCT year FROM comics ORDER BY year
    SQL
    my $sth = $dbh->prepare($select);
    $sth->execute;
    my @years;
    while (my ($this_year) = $sth->fetchrow_array()) {
        my %row;
        if ( $year && $year eq $this_year ) {
            $row{SELECTED} = 'SELECTED';
        }
        $row{YEAR} = $this_year;
        push(@years, \%row);
    }
    $t = _getTitlesDropdown(
        template          => $t,
        selected_title_id => $title_id,
    );
    my $order_by = '';
    if ( $title_id ) {
        $order_by = 'issue_num';
    }
    else {
        $order_by = 'year, issue_num';
    }
    # get items
    $select = <<~"SQL";
    SELECT t.title, issue_num, year, thumb_url, image_page_url, item.notes, storage, 
    item.id AS the_id, g.grade_abbrev, image.id, image.main, image.extension, image.stock, image.notes, 
    (SELECT COUNT(*) FROM comics_images WHERE item_id = the_id)
    FROM comics AS item
    LEFT JOIN comics_images AS image
    ON image.item_id = item.id
    LEFT JOIN comics_titles AS t
    ON t.id = item.title_id
    LEFT JOIN comics_grades AS g
    ON g.id = grade_id
    $where 
    GROUP BY item.id, image.id
    HAVING image.main = 1 OR image.main IS NULL
    ORDER BY $order_by LIMIT $limit
    SQL
    $sth = $dbh->prepare($select);
    $sth->execute;
    my $count = 0;
    my @comics; my @numbers;
    while (my ($title, $issue_num, $year, $thumb_url, $image_page_url, $notes, $storage, $id, $grade_abbrev, $image_id, $main, $image_extension, $stock, $image_notes, $image_count) = $sth->fetchrow_array()) {
        $count++;
        my %row;
        $row{STOCK} = $stock;
        $row{ISSUE_NUM} = $issue_num;
        push(@numbers, $issue_num); # for finding missing issues below
        $row{YEAR} = $year;
        $row{GRADE_ABBREV} = $grade_abbrev;
        $row{NOTES} = $notes || $image_notes;
        # $row{IMAGE_PAGE_URL} = $image_page_url;
        # override database value if new filesystem
        # method is being used
        #my $localcover = "$ENV{DOCUMENT_ROOT}/images/${id}.jpg";
        $row{OFFSITE} = 1;
        my $localcover = '';
        if ( $image_id ) {
            $localcover = "$ENV{DOCUMENT_ROOT}/images/${image_id}.${image_extension}";
            my $size_kb = -s "$localcover" ? int( ( -s "$localcover" ) / 1024 ) : 0;
            $row{SIZE} = $size_kb;
        } 
        if ( -e $localcover ) {
            $thumb_url = "/images/${image_id}.${image_extension}";
            $row{OFFSITE} = 0;
        }
        if ( $image_count > 1 ) {
            $row{IMAGE_COUNT} = $image_count;
        }
        $row{THUMB_URL} = $thumb_url;
        $row{ID} = $id;
        push(@comics, \%row);
    }
    if ( ! $year ) {
        $year = "any year";
    }
    my $average_year = _getAverageYear($title_id);
    my $average_grade = _getAverageGrade($title_id);
    my $total_collection_count = _getTotalCollectionCount();
    $t->param(TITLE => $title);
    $t->param(TITLE_ID => $title_id);
    $t->param(AVERAGE_YEAR => $average_year);
    $t->param(AVERAGE_GRADE => $average_grade);
    $t->param(TOTAL_COLLECTION_COUNT => $total_collection_count);
    $t->param(COUNT => $count);
    my @missing;
    if ( $title_id ) {  # only looking for missing if showing a single title
        @missing = findMissing(@numbers);
        @missing = _collapse_series(@missing);
        $t->param(MISSING => join(", ", @missing));
    }
    if ( ! $year ) {
        $year = "all years";
    }
    $t->param(YEAR => $year);
    $t->param(YEARS => \@years);
    $t->param(COMICS => \@comics);
    #$t->param(MESSAGE => $message . "\n\n$select");
    $t->param(MESSAGE => $message);
    my $output = $t->output;
    print "Content-type: text/html\n\n";
    print $output;
}

=head2 saveCategory()

Add or update an issue from L</editCategory()>.

=cut

sub saveCategory {
    my $id;
    my $category = $cgi->param('category');
    if ( $cgi->param('id') ) {
        $id = $cgi->param('id');
        my $sql = <<~"SQL";
        UPDATE comics_titles
        SET title = ?
        WHERE id = ?
        SQL
        my $rows_updated = $dbh->do(qq{$sql}, undef, $category);
        if ( $rows_updated != 1 ) {
            $IX::Template::message = qq |ERROR: $rows_updated rows updated.|;
        }
    }
    else {
        my $sql = <<~"SQL";
        INSERT INTO comics_titles
        (title) 
        VALUES 
        (?)
        SQL
        my $rows_inserted = $dbh->do(qq{$sql}, undef, $category);
        if ( $rows_inserted != 1 ) {
            IX::Debug::log("ERROR: $rows_inserted rows inserted.");
        }
        else {
            $IX::Template::message = qq |Category added.|;
        }
        # grab the automatically incremented id that was generated
        $id = $dbh->{mysql_insertid} || $dbh->{insertid}; 
    }
    mainInterface();
}

=head2 saveImage()

Add or update an image from L</editIssue()>.

=cut

sub saveImage {
    my $id = $cgi->param('id') || 0;
    my $item_id = $cgi->param('item_id') || 0;
    my $notes = $cgi->param('notes') || 0;
    my $main = $cgi->param('main');
    my $stock = $cgi->param('stock');
    $main = $main eq 'on' ? 1 : 0;
    $stock = $stock eq 'on' ? 1 : 0;
    my $message = '';
    my $ext = '';
    if ( $cgi->param('image') ) {
        if ( $cgi->param('image') =~ m/\.(.+)$/ ) {
            $ext = $1;
        }
    }
    # clear existing 'main' image if this image is set to be the main
    if ( $main ) {
        my $sql = <<~"SQL";
        UPDATE comics_images SET main = 0 WHERE item_id = ?
        SQL
        my $rows_updated = $dbh->do(qq{$sql}, undef, $item_id);
    }
    if ( $cgi->param('id') ) {
        $id = $cgi->param('id');
        my $sql = <<~"SQL";
        UPDATE comics_images
        SET notes = ?, main = ?, stock = ?
        WHERE id = ?
        SQL
        my $rows_updated = $dbh->do(qq{$sql}, undef, $notes, $main, $stock, $id);
        if ( $rows_updated != 1 ) {
            print STDERR "ERROR: $rows_updated rows updated.\n";
        }
    }
    else {
        my $sql = <<~"SQL";
        INSERT INTO comics_images
        (notes, item_id, extension, main, stock)
        VALUES 
        (?, ?, ?, ?, ?)
        SQL
        my $rows_inserted = $dbh->do(qq{$sql}, undef, $cgi->param('notes'), $item_id, $ext, $main, $stock);
        if ( $rows_inserted != 1 ) {
            print STDERR "ERROR: $rows_inserted rows inserted.\n";
        }
        else {
            $message = "Item added.";
        }
        # grab the automatically incremented id that was generated
        $id = $dbh->{mysql_insertid} || $dbh->{insertid}; 
    }
    # NOTE: this goes after db insert so we can use the id from that for filename
    if ( $cgi->param('image') ) {
        open (FILE, "> $ENV{DOCUMENT_ROOT}/images/${id}.${ext}") or die "$!";
        binmode FILE;
        my $image = $cgi->param('image');
        while ( <$image> ) {
            print FILE;
        }
        close FILE;
    }
    editIssue( $item_id );
}

=head2 saveIssue()

Add or update an issue from L</editIssue()>.

=cut

sub saveIssue {
    my $id; my $message = '';
    my $grade_id = $cgi->param('grade_id') || 0;
    if ( $cgi->param('id') ) {
        $id = $cgi->param('id');
        my $sql = <<~"SQL";
        UPDATE comics
        SET title_id = ?, issue_num = ?, year = ?, thumb_url = ?, image_page_url = ?, notes = ?, grade_id = ?
        WHERE id = ?
        SQL
        my $rows_updated = $dbh->do(qq{$sql}, undef, $cgi->param('title_id'), $cgi->param('issue_num'), $cgi->param('year'), $cgi->param('thumb_url'), $cgi->param('image_page_url'), $cgi->param('notes'), $grade_id, $id);
        if ( $rows_updated != 1 ) {
            print STDERR "ERROR: $rows_updated rows updated.\n";
        }
    }
    else {
        my $sql = <<~"SQL";
        INSERT INTO comics
        (title_id, issue_num, year, thumb_url, image_page_url, notes, grade_id) 
        VALUES 
        (?, ?, ?, ?, ?, ?, ?)
        SQL
        my $rows_inserted = $dbh->do(qq{$sql}, undef, $cgi->param('title_id'), $cgi->param('issue_num'), $cgi->param('year'), $cgi->param('thumb_url'), $cgi->param('image_page_url'), $cgi->param('notes'), $grade_id);
        if ( $rows_inserted != 1 ) {
            IX::Debug::log("ERROR: $rows_inserted rows inserted.");
        }
        else {
            $message = "Item added.";
        }
        # grab the automatically incremented id that was generated
        $id = $dbh->{mysql_insertid} || $dbh->{insertid}; 
    }
    my $ungraded = 1;
    $ungraded = 0 if $grade_id;
    mainInterface( ungraded => $ungraded, message => $message );
}

=head1 INTERNAL SUBROUTINES

=head2 _collapse_series

Given an array of integers, collapse it and return an array with any series represented like MIN-MAX.

=cut

sub _collapse_series {
    my @arr = @_;
    my @result;
    my $start = $arr[0]; # Initialize the start of the first series
    for ( my $i = 1; $i <= @arr; $i++ ) {
        if ( $i == @arr || $arr[$i] != $arr[$i-1] + 1 ) {
            # Finalize the series
            if ( $start == $arr[$i-1] ) {
                # Single number, no range
                push @result, $start;
            } 
            elsif ( $arr[$i-1] == $start + 1 ) {
                # Series of exactly two numbers, do not collapse
                push @result, $start, $arr[$i-1];
            }
            else {
                # Collapse the series of three or more numbers
                push @result, "$start-$arr[$i-1]";
            }
            $start = $arr[$i]; # Start a new series
        }
    }
    return @result;
}

=head2 _getAverageYear()

Return the average publishing year of al the issues in the collection.

=cut

sub _getAverageYear {
    my $title_id = $_[0];
    my $where = ''; my @bind_vars;
    if ( $title_id ) {
        $where = 'WHERE title_id = ?';
        push(@bind_vars, $title_id);
    }
    my $select = <<~"SQL";
    SELECT ROUND(AVG(year)) FROM comics $where
    SQL
    my $sth = $dbh->prepare($select) || die "prepare: $select: $DBI::errstr";
    $sth->execute(@bind_vars) || die "execute: $select: $DBI::errstr";
    my ($average_year) = $sth->fetchrow_array();
    return $average_year;
}

=head2 _getAverageGrade()

Return the average grade of all the issues in the collection.

Only the best copy of each issue in the collection is graded, in the few cases where we keep multiple copies of an issue.

=cut

sub _getAverageGrade {
    my $title_id = $_[0];
    my $where = ''; my @bind_vars;
    if ( $title_id ) {
        $where = 'WHERE title_id = ?';
        push(@bind_vars, $title_id);
    }
    my $select = <<~"SQL";
    SELECT ROUND(AVG(cgc_number), 1) FROM comics
    LEFT JOIN comics_grades AS g
    ON g.id = grade_id
    $where
    SQL
    my $sth = $dbh->prepare($select) || die "prepare: $select: $DBI::errstr";
    $sth->execute(@bind_vars) || die "execute: $select: $DBI::errstr";
    my ($average_cgc_num) = $sth->fetchrow_array();
    return $average_cgc_num;
}

=head2 _getGradesDropdown()

Given a template object, return that object populated with a selector for grades.

=cut

sub _getGradesDropdown {
    my %arg = @_;
    my $t = $arg{template};
    my $selected_grade_id = $arg{selected_grade_id};
    my @grades;
    my $select = <<~"SQL";
    SELECT grade, grade_abbrev, id, cgc_number
    FROM comics_grades
    ORDER BY cgc_number
    SQL
    my $sth = $dbh->prepare($select) || die "prepare: $select: $DBI::errstr";
    $sth->execute || die "execute: $select: $DBI::errstr";
    while (my ($grade, $grade_abbrev, $id, $cgc_number) = $sth->fetchrow_array()) {
        my %row;
        if ( $selected_grade_id eq $id ) {
            $row{SELECTED} = 'SELECTED';
        }
        $row{GRADE} = $grade;
        $row{GRADE_ABBREV} = $grade_abbrev;
        $row{CGC_NUMBER} = $cgc_number;
        $row{ID} = $id;
        push(@grades, \%row);
    }
    $t->param(GRADES => \@grades);
    return $t;
}

=head2 getLeastRecentYear()

Return the oldest publishing year of all items in the collection.

=cut

sub _getLeastRecentYear {
    my $select = <<~"SQL";
    SELECT year FROM comics ORDER BY year ASC LIMIT 1
    SQL
    my $sth = $dbh->prepare($select) || die "prepare: $select: $DBI::errstr";
    $sth->execute || die "execute: $select: $DBI::errstr";
    my ($most_recent_year) = $sth->fetchrow_array();
    return $most_recent_year;
}

=head2 getMostRecentYear()

Return the most recent publishing year of all items in the collection.

=cut

sub _getMostRecentYear {
    my $select = <<~"SQL";
    SELECT year FROM comics ORDER BY year DESC LIMIT 1
    SQL
    my $sth = $dbh->prepare($select) || die "prepare: $select: $DBI::errstr";
    $sth->execute || die "execute: $select: $DBI::errstr";
    my ($most_recent_year) = $sth->fetchrow_array();
    return $most_recent_year;
}

=head2 _getTitlesDropdown()

Given a template object, return that object populated with a selector for titles.

=cut

sub _getTitlesDropdown {
    my %arg = @_;
    my $t = $arg{template};
    my $selected_title_id = $arg{selected_title_id};
    my @titles;
    my $select = <<~"SQL";
    SELECT DISTINCT title, comics_titles.id FROM comics_titles 
    JOIN comics ON comics_titles.id = comics.title_id
    ORDER BY title
    SQL
    my $sth = $dbh->prepare($select) || die "prepare: $select: $DBI::errstr";
    $sth->execute || die "execute: $select: $DBI::errstr";
    while (my ($this_title, $id) = $sth->fetchrow_array()) {
        my %row;
        if ( $selected_title_id && $selected_title_id eq $id ) {
            $row{SELECTED} = 'SELECTED';
        }
        $row{TITLE} = $this_title;
        $row{ID} = $id;
        push(@titles, \%row);
    }
    $t->param(TITLES => \@titles);
    return $t;
}

=head2 _getTotalCollectionCount()

Return the total number of issues in the collection.

=cut

sub _getTotalCollectionCount {
    my $select = <<~"SQL";
    SELECT COUNT(*) FROM comics
    SQL
    my $sth = $dbh->prepare($select) || die "prepare: $select: $DBI::errstr";
    $sth->execute || die "execute: $select: $DBI::errstr";
    my ($count) = $sth->fetchrow_array();
    # commify
    $count =~ s/(?<=\d)(?=(\d{3})+$)/,/g;
    return $count;
}

=head1 AUTHOR

Marcus Del Greco L</mailto:marcus@mindmined.com>.

=cut




