#!/usr/bin/perl

use strict;
use warnings;

# we use indented HEREDOCs among other things
# so require a minimum Perl version
use 5.026;

# this is needed until we can
# use 5.036 when it is enabled by default
use feature 'signatures';

use lib qw(
    .
    local/lib/perl5
    local/lib/perl5/x86_64-linux-thread-multi
);

use Data::Dumper;
use DBI;
use FindBin;
use JSON;
use Dotenv;
use Getopt::Long;
use OpenAI::API;

Dotenv->load;

=head1 assess

Use AI to assess value of collectible items in a given condition, starting with comic books and magazines.

=cut

=head2 main

Get credentials, connect to the database, and run the assessment.

By default, the program will grab just one record and attempt to assess, one that has either never been assessed, or the least recently assessed if all have been assessed before.

    ./assess.pl

However, if C<--limit=[limit]> is provided, it will assess that number of collectibles from the database.

Alternately, if C<--id=id> is provided, only the record from C<items> with that id will be assessed.

=cut

my $dsn = "DBI:mysql:database=$ENV{DB};host=$ENV{DB_HOST}";
my $dbh = DBI->connect(
    $dsn,
    "$ENV{DB_USER}",
    "$ENV{DB_PASS}", {
        RaiseError => 1,  # dies on errors
    }
) || die "Connect failed: $DBI::errstr\n"; 

my $limit = 1; my $id = 0; my $title_id = 0;
my $verbose; my $new;
GetOptions (
    "limit=i" => \$limit,       # --limit=[limit]
    "id=i"    => \$id,          # --id=[id]
    "title_id=i" => \$title_id, # --id=[id]
    "new"     => \$new,         # flag, -new (only process unassessed items)
    "verbose" => \$verbose      # flag, -verbose
) or die("Error in command line arguments\n");

# only the one record, if given
my $and = ''; my @bind_vars;
if ( $id ) {
    $and = 'AND i.id = ?';
    push(@bind_vars, $id);
}

my $and_title_id = '';
if ( $title_id ) {
    $and_title_id = 'AND t.id = ?';
    push(@bind_vars, $title_id);
}

my $and_new = '';
if ( $new ) {
    $and_new = 'AND ( i.value = 0.00 OR i.value IS NULL )';
}

my $api = OpenAI::API->new( api_key => $ENV{OPENAI_API_KEY} );

my $sys_prompt_comic_mag = <<"PROMPT";
You are a highly accurate comic book and magazine price guide expert.
You must estimate the fair market value of comics and magazines based on historical sales, market trends, and CGC pricing data. 
First, determine the appropriate price range for the book.
Then, return only the midpoint value of that range, formatted as a number with two decimal places, such as '1300.00'.
No text, symbols, or explanations—just the number.
PROMPT

my $count = 0;

my $select = <<~"SQL";
SELECT i.id, t.title, i.volume, i.issue_num, i.year, cg.grade, cg.cgc_number, i.value
FROM items AS i
LEFT JOIN titles AS t
ON i.title_id = t.id
LEFT JOIN comic_grades AS cg
ON i.grade_id = cg.id
WHERE (
    t.`type` = 'comic'
    OR 
    t.`type` = 'magazine'
)
$and
$and_new
$and_title_id
ORDER BY value_datetime
SQL
my $sth = $dbh->prepare($select);
$sth->execute(@bind_vars);
while (my ($item_id, $title, $volume, $issue_num, $year, $grade, $grade_number, $existing_value) = $sth->fetchrow_array()) {
    $volume = '' unless $volume;
    $grade = '' unless $grade;
    $grade_number = '' unless $grade_number;
    if ( ! $grade ) {
        if ( $id || $verbose ) {
            # only explain why skipping if processing a single item
            print STDOUT "Item: $title Volume: $volume, Issue $issue_num\n";
            print STDOUT "\t - SORRY: cannot assess item without a grade.\n";
        }
        next;
    }
    $count++;
    last if $count > $limit;
    my $user_prompt_comic_mag = <<"USER";
Estimate the fair market value of the following comic book based on recent sales, market trends, and industry standards:
Comic Book: $title
Volume: $volume
Issue #: $issue_num
Year: $year
Grade: $grade $grade_number

Determine the most reliable price range, then return only the midpoint value in USD, formatted as a number with two decimal places (e.g., 1300.00).
USER
    my $response = $api->chat(
        model => "gpt-4-turbo",
        messages => [
            { role => "system", content => $sys_prompt_comic_mag },
            { role => "user", content => $user_prompt_comic_mag }
        ],
        max_tokens => 100,
        temperature => 0.0
    );
    print Dumper($response) if $verbose;
    print "Item: $title Volume: $volume, Issue $issue_num ($year) $grade ($grade_number)\n";
    my $value = $response->{choices}[0]{message}{content};
    print "Estimated Value: \$$value (Previous Estimate: \$$existing_value)\n";
    my $sql = <<~"SQL";
    UPDATE items SET value = ?, value_datetime = NOW()
    WHERE id = ?
    SQL
    my $rows_updated = $dbh->do(qq{$sql}, undef, $value, $item_id);
    if ( $rows_updated != 1 ) {
        print STDERR "ERROR: $rows_updated rows updated.\n";
    }
}

=head1 AUTHOR

Marcus Del Greco L</mailto:marcus@mindmined.com>.

=cut




