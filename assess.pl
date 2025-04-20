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
use HTML::Template;
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

# load prompt template objects
my %prompt_templates = (
    card => {
        sys  => HTML::Template->new(filename => 'prompts/sys/card.tmpl'),
        user => HTML::Template->new(filename => 'prompts/user/card.tmpl', die_on_bad_params => 0),
    },
    comic => {
        sys  => HTML::Template->new(filename => 'prompts/sys/comic.tmpl'),
        user => HTML::Template->new(filename => 'prompts/user/comic.tmpl', die_on_bad_params => 0),
    },
    magazine => {
        sys  => HTML::Template->new(filename => 'prompts/sys/magazine.tmpl'),
        user => HTML::Template->new(filename => 'prompts/user/magazine.tmpl', die_on_bad_params => 0),
    },
);


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
SELECT i.id AS item_id, t.title AS title, i.volume AS volume, i.issue_num AS issue_num, 
i.year AS year, cg.grade AS grade, cg.cgc_number AS grade_number, i.value AS existing_value, 
t.`type` AS `type`, i.value_datetime AS existing_value_datetime
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
#while (my ($item_id, $title, $volume, $issue_num, $year, $grade, $grade_number, $existing_value, $type) = $sth->fetchrow_array()) {
while (my $i = $sth->fetchrow_hashref()) {
    $i->{volume} = 'unspecified' unless $i->{volume};
    $i->{grade} = '' unless $i->{grade};
    $i->{grade_number} = '' unless $i->{grade_number};
    $i->{existing_value_datetime} = '' unless $i->{existing_value_datetime};
    if ( ! $i->{grade} ) {
        if ( $id || $verbose ) {
            # only explain why skipping if processing a single item
            print STDOUT "Item: $i->{title} Volume: $i->{volume}, Issue $i->{issue_num}\n";
            print STDOUT "\t - SORRY: cannot assess item without a grade.\n";
        }
        next;
    }
    $count++;
    last if $count > $limit;
    my $sys_prompt = _sysPrompt($i->{type});
    my $user_prompt = _userPrompt($i);
    my $response;
    $response = $api->chat(
        model => "gpt-4-turbo",
        messages => [
            { role => "system", content => $sys_prompt },
            { role => "user", content => $user_prompt }
        ],
        max_tokens => 100,
        temperature => 0.0
    );
    print Dumper($response) if $verbose;
    print "Item: $i->{title} Volume: $i->{volume}, Issue $i->{issue_num} ($i->{year}) $i->{grade} ($i->{grade_number})\n";
    my $value = $response->{choices}[0]{message}{content};
    # compute % change
    my $sign = ''; my $diff = 0; my $perc_diff = 0; my $color = 'white';
    if ( $value > $i->{existing_value} ) {
        $sign = '+';
        $diff = $value - $i->{existing_value};
        $perc_diff = $diff / $i->{existing_value} * 100;
        $color = 'bright_green';
    }
    elsif ( $value < $i->{existing_value} ) {
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
    print "Estimate: $value_str, Previous ($i->{existing_value_datetime}): \$$i->{existing_value}, $diff_str ($perc_diff_str) change\n";
    my $sql = <<~"SQL";
    UPDATE items SET value = ?, value_datetime = NOW()
    WHERE id = ?
    SQL
    my $rows_updated = $dbh->do(qq{$sql}, undef, $value, $i->{item_id});
    if ( $rows_updated != 1 ) {
        print STDERR "ERROR: $rows_updated rows updated.\n";
    }
}

=head1 SUBROUTINES

=head2 _userPrompt

Given a reference to item data, return the appropriate user prompt for an LLM.

=cut

sub _userPrompt {
    my $i = $_[0];
    my $t = $prompt_templates{ $i->{type} }->{user};
    # we turn off die_on_bad_params in HTML::Template
    # because only some of these will be populated for each type
    $t->param(VOLUME => $i->{volume});
    $t->param(TITLE => $i->{title});
    $t->param(ISSUE_NUM => $i->{issue_num});
    $t->param(YEAR => $i->{year});
    $t->param(GRADE => $i->{grade});
    $t->param(GRADE_NUMBER => $i->{grade_number});
    return $t->output;
}

=head2 _sysPrompt

Given an item type, return the appropriate system prompt for an LLM.

=cut

sub _sysPrompt {
    my $type = $_[0];
    my $t = $prompt_templates{$type}->{sys};
    # nothing to replace in system prompt as it is
    # a general instruction
    return $t->output;
}

=head1 AUTHOR

Marcus Del Greco L</mailto:marcus@mindmined.com>.

=cut




