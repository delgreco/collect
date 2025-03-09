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

Use AI to assess value of collectible items in a given condition, starting with comic books.

=cut

=head2 main

Get credentials, connect to the database, and run the assessment.

By default, the program will grab just one record at random and attempt to assess.

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

my $limit = 1; my $id = 0;
my $verbose;
GetOptions ("limit=i" => \$limit,
            "id=i"    => \$id,
            "verbose"  => \$verbose)   # flag
or die("Error in command line arguments\n");

# only the one record, if given
my $where = ''; my @bind_vars;
if ( $id ) {
    $where = 'WHERE i.id = ?';
    push(@bind_vars, $id);
}

my $api = OpenAI::API->new( api_key => $ENV{OPENAI_API_KEY} );

my $count = 0;

my $select = <<~"SQL";
SELECT i.id, t.title, issue_num, cg.grade, cg.cgc_number 
FROM items AS i
LEFt JOIN titles AS t
ON i.title_id = t.id
LEFT JOIN comic_grades AS cg
ON i.grade_id = cg.id
$where
SQL
my $sth = $dbh->prepare($select);
$sth->execute(@bind_vars);
while (my ($id, $title, $issue_num, $grade, $grade_number) = $sth->fetchrow_array()) {
    $count++;
    last if $count > $limit;
    $grade = '' unless $grade;
    $grade_number = '' unless $grade_number;
    my $response = $api->chat(
        # model => "gpt-3.5-turbo",
         model => "gpt-4-turbo",
        # model => "gpt-4",
        messages => [
            { role => "system", content => "You are a highly accurate comic book price guide expert. You must estimate the fair market value of comics based on historical sales, market trends, and CGC pricing data. First, determine the appropriate price range for the book. Then, return only the midpoint value of that range, formatted as a number with two decimal places, such as '1300.00'. No text, symbols, or explanations—just the number." },
            { role => "user", content => "Estimate the fair market value of the following comic book based on recent sales, market trends, and industry standards:\n\nComic Book: $title\nIssue #: $issue_num\nGrade: $grade $grade_number\n\nDetermine the most reliable price range, then return only the midpoint value in USD, formatted as a number with two decimal places (e.g., 1300.00)." }
        ],
        max_tokens => 100,
        temperature => 0.1
    );
    print Dumper($response) if $verbose;
    # print "Model used: $response->{model}\n";
    print "Item: $title $issue_num $grade $grade_number\n";
    print "Estimated Price: " . $response->{choices}[0]{message}{content} . "\n";
}

=head1 AUTHOR

Marcus Del Greco L</mailto:marcus@mindmined.com>.

=cut




