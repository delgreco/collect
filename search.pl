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

my $limit = 1; my $id = 0; my $title_id = 0;
my $verbose;
GetOptions(
    "limit=i" => \$limit,       # --limit=[limit]
    "id=i"    => \$id,          # --id=[id]
    "title_id=i" => \$title_id, # --id=[id]
    "verbose" => \$verbose      # flag, -verbose
) or die("Error in command line arguments\n");

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
WHERE (
    t.`type` = 'comic'
    OR 
    t.`type` = 'magazine'
    OR 
    t.`type` = 'card'
)
$and
$and_new
$and_title_id
ORDER BY value_datetime
SQL
my $sth = $dbh->prepare($select);
$sth->execute(@bind_vars);
while (my $i = $sth->fetchrow_hashref()) {
    if ( $type && $i->{type} ne $type ) {
        print STDOUT "Skipping as not type '$type'.\n" if $id || $verbose;
        next;
    }
    $i->{volume} = 'unspecified' unless $i->{volume};
    $i->{grade} = '' unless $i->{grade};
    $i->{grade_number} = '' unless $i->{grade_number};
    $i->{notes} = 'none' unless $i->{notes};
    $i->{existing_value_datetime} = '' unless $i->{existing_value_datetime};
    $i->{existing_value} = 0 unless $i->{existing_value};
    if ( 
        ( $i->{type} eq 'comic' || $i->{type} eq 'magazine' )
        &&
        ! $i->{grade} 
    ) {
        if ( $id || $verbose ) {
            # only explain why skipping if processing a single item
            print STDOUT "Item: $i->{title} Volume: $i->{volume}, Issue $i->{issue_num}\n";
            print STDOUT "\t - SORRY: cannot assess item without a grade.\n";
        }
        next;
    }
    $count++;
    last if $count > $limit;
    my ($sys_prompt, $user_prompt) = Collect::getPrompt($i, 'estimate');
    print "User Prompt: $user_prompt\n" if $verbose;
    my $response;
    $response = $api->chat(
        model => "gpt-4-turbo",
        messages => [
            { role => "system", content => $sys_prompt },
            { role => "user", content => $user_prompt }
        ],
        max_tokens => 10,
        temperature => 0.0
    );
    print Dumper($response) if $verbose;
    my $issue_or_card = 'Issue';
    if ( $i->{type} eq 'card' ) {
        $issue_or_card = 'Card';
    }
    my $grade_number_str = '';
    $grade_number_str = "($i->{grade_number})" if $i->{grade_number};
    print "$i->{title}, Volume: $i->{volume}, $issue_or_card $i->{issue_num} ($i->{year}) $i->{grade} $grade_number_str\n";
    my $value = $response->{choices}[0]{message}{content};
    # compute % change
    my $sign = ''; my $diff = 0; my $perc_diff = 0; my $color = 'white';
    if ( $i->{existing_value} && $i->{existing_value} > 0 && $value > $i->{existing_value} ) {
        $sign = '+';
        $diff = $value - $i->{existing_value};
        $perc_diff = $diff / $i->{existing_value} * 100;
        $color = 'bright_green';
    }
    elsif ( $i->{existing_value} && $i->{existing_value} > 0 && $value < $i->{existing_value} ) {
        $sign = '-';
        $diff = $i->{existing_value} - $value;
        $perc_diff = $diff / $i->{existing_value} * 100;
        $color = 'red';
    }
    else {
        # no change
    }
    my $value_str = color("bright_green") . "\$$value" . color("reset");
    $diff = sprintf("%.2f", $diff);
    my $diff_str = color("$color") . "${sign}\$${diff}" . color("reset");
    $perc_diff = POSIX::round($perc_diff);
    my $perc_diff_str = color("$color") . "${sign}\%${perc_diff}" . color("reset");
    print "\tID: $i->{item_id}, Notes: $i->{notes}\n";
    print "\tEstimate: $value_str, Previous ($i->{existing_value_datetime}): \$$i->{existing_value}, $diff_str ($perc_diff_str) change\n";
    my $sql = <<~"SQL";
    UPDATE items SET value = ?, value_datetime = NOW()
    WHERE id = ?
    SQL
    my $rows_updated = $dbh->do(qq{$sql}, undef, $value, $i->{item_id});
    if ( $rows_updated != 1 ) {
        print STDERR "ERROR: $rows_updated rows updated.\n";
    }
    $batch_total_now += $value;
    $batch_total_previous += $i->{existing_value} if defined $i->{existing_value};
}

if ( $limit > 1 ) {
    my $batch_diff        = $batch_total_now - $batch_total_previous;
    my $batch_sign        = $batch_diff > 0 ? '+' : $batch_diff < 0 ? '-' : '';
    my $batch_color       = $batch_diff > 0 ? 'bright_green' : $batch_diff < 0 ? 'red' : 'white';
    my $batch_diff_abs    = sprintf("%.2f", abs($batch_diff));
    my $batch_perc_diff   = $batch_total_previous > 0
                        ? sprintf("%.0f", abs($batch_diff) / $batch_total_previous * 100)
                        : 0;
    my $batch_diff_str        = color($batch_color) . "${batch_sign}\$${batch_diff_abs}" . color("reset");
    my $batch_perc_diff_str   = color($batch_color) . "${batch_sign}\%${batch_perc_diff}" . color("reset");
    say "\nTotal Estimate (batch): $batch_diff_str ($batch_perc_diff_str) change";
}

=head1 AUTHOR

Marcus Del Greco L</mailto:marcus@mindmined.com>.

=cut




