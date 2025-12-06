#!/usr/bin/perl

use strict;
use warnings;

# we use indented HEREDOCs among other things
# so require a minimum Perl version
use 5.026;

# this is needed until we can
# use 5.036 when it is enabled by default
no warnings 'experimental::signatures';
use feature 'signatures';

use lib qw(
    .
    local/lib/perl5
    local/lib/perl5/x86_64-linux-thread-multi
);

use Data::Dumper;
use DBI;
use FindBin;
use POSIX;
use Term::ANSIColor;
use JSON;
use Dotenv;
use Getopt::Long;

Dotenv->load;

# our own module
use Collect;

=head1 search

Use AI to search for current listings of collectibles for sale, at or below a given price point for condition.

=cut

=head2 main

Get credentials, connect to the database, and run the search for the given item id.

    ./search.pl --id=[id]

=cut

my $debug_mode = 0;

my $dsn = "DBI:mysql:database=$ENV{DB};host=$ENV{DB_HOST}";
my $dbh = DBI->connect(
    $dsn,
    "$ENV{DB_USER}",
    "$ENV{DB_PASS}", {
        RaiseError => 1,  # dies on errors
    }
) || die "Connect failed: $DBI::errstr\n"; 

my $id = 0;
my $search = ''; my $price = 0;  my $min_grade = '';
my $help;
GetOptions(
    'search=s' => \$search,
    'price=i' => \$price,
    'min-grade=f' => \$min_grade,

    "id=i"    => \$id,          # --id=[id]
    'help'    => \$help,        # flag, --help
) or die("Error in command line arguments\n");

if ( $help ) {
    help();
}

if ( ! $id ) {
    unless ( $search && $price ) {
        help();
    }
}

# only the one record, if given
if ( $id ) {
    my $and = ''; my @bind_vars;
    $and = 'AND i.id = ?';
    push(@bind_vars, $id);
    # data about the item we are shopping
    my $select = <<~"SQL";
    SELECT i.id AS item_id, t.title AS title, i.volume AS volume, i.issue_num AS issue_num, 
    i.year AS year, g_comics.grade AS grade, g_comics.cgc_number AS grade_number, i.value AS existing_value, 
    t.`type` AS `type`, i.value_datetime AS existing_value_datetime, i.notes AS notes,
    g_cards.PSA_number AS PSA_number, g_cards.grade AS PSA_grade, g_cards.grade_abbrev AS PSA_grade_abbrev
    FROM items AS i
    LEFT JOIN titles AS t
    ON i.title_id = t.id
    LEFT JOIN grades_comics g_comics
    ON i.grade_id = g_comics.id
    LEFT JOIN grades_cards AS g_cards
    ON i.PSA_grade_id = g_cards.id
    WHERE i.id = ?
    SQL
    my $sth = $dbh->prepare($select);
    $sth->execute(@bind_vars);
    my $i = $sth->fetchrow_hashref();

    $i->{volume} = 'unspecified' unless $i->{volume};
    $i->{grade} = '' unless $i->{grade};
    $i->{grade_number} = '' unless $i->{grade_number};
    $i->{notes} = 'none' unless $i->{notes};
    $i->{existing_value_datetime} = '' unless $i->{existing_value_datetime};
    $i->{existing_value} = 0 unless $i->{existing_value};

    $search = "$i->{title} #$i->{issue_num} $i->{year}";
    $price = $i->{existing_value};
    $min_grade = $i->{grade_number};
}

my ($filtered_items, $filter_message) = Collect::searchEbay(
    $search, 
    $price, 
    $min_grade
);

if ( @$filtered_items ) {
    if ( $debug_mode ) {
        print "\n--- Raw Data for First Item (for inspection) ---\n";
        $Data::Dumper::Sortkeys = 1;
        $Data::Dumper::Deepcopy = 1;
        $Data::Dumper::Terse = 1;
        print Dumper($filtered_items->[0]);
        print "------------------------------------------------\n\n";
        exit 0;
    }
    
    print "\nDisplayed " . scalar(@$filtered_items) . " listings matching your criteria:\n";
    print "----------------------------------------\n";
    foreach my $item ( @$filtered_items ) {
        my $title = $item->{title} || 'N/A';
        my $price_value = $item->{price}{value} || 'N/A';
        my $price_currency = $item->{price}{currency} || '';
        my $item_web_url = $item->{itemWebUrl} || 'N/A';
        my $condition = $item->{condition} || 'N/A';
        my $publication_year = $item->{publicationYear} || 'N/A';
        my $issue_number = $item->{'issueNumber'} || 'N/A';
        my $grade = $item->{grade} || 'N/A';
        my $seller_username = $item->{seller}{username} || 'N/A';
        my $shipping_cost_value = ($item->{shippingOptions} && $item->{shippingOptions}[0] && $item->{shippingOptions}[0]{shippingCost}{value}) ? $item->{shippingOptions}[0]{shippingCost}{value} : 'N/A';
        my $shipping_cost_currency = ($item->{shippingOptions} && $item->{shippingOptions}[0] && $item->{shippingOptions}[0]{shippingCost}{currency}) ? $item->{shippingOptions}[0]{shippingCost}{currency} : '';
        my $location_country = $item->{itemLocation}{country} || 'N/A';
        my $top_rated_seller = (defined $item->{topRatedBuyingExperience} && $item->{topRatedBuyingExperience}) ? 'Yes' : 'No';
        my $category_name = $item->{categoryPath} || 'N/A';
        print "Title: $title\n";
        print "Condition: $condition\n";
        print "Year: $publication_year\n";
        print "Issue Number: $issue_number\n";
        print "Grade: $grade\n";
        print "Price: $price_value $price_currency\n";
        print "Shipping: $shipping_cost_value $shipping_cost_currency\n";
        print "Seller: $seller_username (Top Rated: $top_rated_seller)\n";
        print "Location: $location_country\n";
        print "Category: $category_name\n";
        print "URL: $item_web_url\n";
        print "Image URL: " . (($item->{image} && $item->{image}{imageUrl}) ? $item->{image}{imageUrl} : 'N/A') . "\n";
        print "----------------------------------------\n";
        print "Filter: $filter_message\n";
        print "----------------------------------------\n";
    }
}

=head1 SUBROUTINES

=head2 help()

Provide CLI help.

=cut

sub help {
    print "Usage: $0 --id <id>\n";
    print "  or...\n";
    print "Usage: $0 --search <title #issue year> --price <max_price> [--min-grade <grade>]\n";
    print "  --id <id>                    : The id of the item to be shopped for.\n";
    print "  or...\n";
    print "  --search <title #issue year> : Required title of comic book to search for.\n";
    print "  --price <max_price>          : Required maximum price for the comic book.\n";
    print "  --min-grade <grade>          : Optional minimum grade an item must have (e.g., 9.0).\n";
    exit;
}


=head1 AUTHOR

Marcus Del Greco L</mailto:marcus@mindmined.com>.

=cut




