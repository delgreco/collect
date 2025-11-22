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
GetOptions(
    "limit=i" => \$limit,       # --limit=[limit]
    "id=i"    => \$id,          # --id=[id]
    "verbose" => \$verbose      # flag, -verbose
) or die("Error in command line arguments\n");

die "ERROR: --id required.\n" if ! $id;

my $and = ''; my @bind_vars;
if ( $id ) {
    $and = 'AND i.id = ?';
    push(@bind_vars, $id);
}

my $api = OpenAI::API->new( api_key => $ENV{OPENAI_API_KEY} );

my $count = 0;

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

# if ( $type && $i->{type} ne $type ) {
#     print STDOUT "Skipping as not type '$type'.\n" if $id || $verbose;
#     next;
# }

$i->{volume} = 'unspecified' unless $i->{volume};
$i->{grade} = '' unless $i->{grade};
$i->{grade_number} = '' unless $i->{grade_number};
$i->{notes} = 'none' unless $i->{notes};
$i->{existing_value_datetime} = '' unless $i->{existing_value_datetime};
$i->{existing_value} = 0 unless $i->{existing_value};

my ($sys_prompt, $user_prompt) = Collect::getPrompt($i, 'listings');
print "User Prompt: $user_prompt\n" if $verbose;

my $response = $api->chat(
    model => "gpt-4-turbo",
    messages => [
        { role => "system", content => $sys_prompt },
        { role => "user", content => $user_prompt }
    ],
    max_tokens => 800,
    temperature => 0.0,
    tools => [
        {
            "type" => "web",
            "web" => {
                "search" => {}
            },
        },
    ],
);
print Dumper($response) if $verbose;

my $listings_ref = decode_json($response->{choices}[0]{message}{content});

foreach my $url ( sort keys %$listings_ref ) {
    print "URL: $url\n";
}

=head1 AUTHOR

Marcus Del Greco L</mailto:marcus@mindmined.com>.

=cut




