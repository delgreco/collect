package Collect;

# this is needed until we can
# use 5.036 when it is enabled by default
no warnings 'experimental::signatures';
use feature 'signatures';

=head1 Collect.pm

Some functionality to be shared by the CGI program and the command line 'assess' program.

=cut

use OpenAI::API;

=head2 userPrompt

Given a reference to item data C<$i> and a type of C<$prompt>, return the appropriate user prompt for an LLM.

=cut

sub getPrompt( $i, $prompt ) {
    my $t_sys = HTML::Template->new(
        filename          => "prompts/$prompt/sys/$i->{type}.tmpl",
    );
    # we turn off die_on_bad_params in HTML::Template
    # because only some of these will be populated for each type
    my $t_user = HTML::Template->new(
        filename          => "prompts/$prompt/user/$i->{type}.tmpl",
        die_on_bad_params => 0,
    );
    $t_user->param(VOLUME => $i->{volume});
    $t_user->param(TITLE => $i->{title});
    $t_user->param(ISSUE_NUM => $i->{issue_num});
    $t_user->param(YEAR => $i->{year});
    $t_user->param(PSA_NUMBER => $i->{PSA_number});
    $t_user->param(PSA_GRADE => $i->{PSA_grade});
    $t_user->param(PSA_GRADE_ABBEV => $i->{PSA_grade_abbrev});
    $t_user->param(GRADE => $i->{grade});
    $t_user->param(GRADE_NUMBER => $i->{grade_number});
    $t_user->param(NOTES => $i->{notes});
    return ($t_sys->output, $t_user->output);
}

1;

