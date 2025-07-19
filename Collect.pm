package Collect;

=head1 Collect.pm

Some functionality to be shared by the CGI program and the command line 'assess' program.

=cut

use OpenAI::API;

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

=head2 userPrompt

Given a reference to item data, return the appropriate user prompt for an LLM.

=cut

sub userPrompt {
    my $i = $_[0];
    my $t = $prompt_templates{ $i->{type} }->{user};
    # we turn off die_on_bad_params in HTML::Template
    # because only some of these will be populated for each type
    $t->param(VOLUME => $i->{volume});
    $t->param(TITLE => $i->{title});
    $t->param(ISSUE_NUM => $i->{issue_num});
    $t->param(YEAR => $i->{year});
    $t->param(PSA_NUMBER => $i->{PSA_number});
    $t->param(PSA_GRADE => $i->{PSA_grade});
    $t->param(PSA_GRADE_ABBEV => $i->{PSA_grade_abbrev});
    $t->param(GRADE => $i->{grade});
    $t->param(GRADE_NUMBER => $i->{grade_number});
    $t->param(NOTES => $i->{notes});
    return $t->output;
}

=head2 sysPrompt

Given an item type, return the appropriate system prompt for an LLM.

=cut

sub sysPrompt {
    my $type = $_[0];
    my $t = $prompt_templates{$type}->{sys};
    # nothing to replace in system prompt as it is
    # a general instruction
    return $t->output;
}

1;

