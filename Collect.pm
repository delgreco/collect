package Collect;

# this is needed until we can
# use 5.036 when it is enabled by default
no warnings 'experimental::signatures';
use feature 'signatures';

use HTML::Template;
use OpenAI::API;
use LWP::UserAgent;
use URI;
use JSON;
use Try::Tiny;
use MIME::Base64 qw( encode_base64 );

=head1 Collect.pm

Some functionality to be shared by the CGI program and the command line utilities.

=cut

=head2 _load_grade_mappings()

Internal routine to match strings indicating comics grades such as VF, Very Fine, 8.0 and map them to the numerical grade of, in this example, 8.0.

=cut

sub _load_grade_mappings {
    return [
        { grade => '9.9', regex => qr/(?:9\.9|\bM Mint\b|Mint \(slabbed comics only\))/i },
        { grade => '9.8', regex => qr/(?:9\.8|\bNM\/M\b|\bNear Mint\/Mint\b)/i },
        { grade => '9.6', regex => qr/(?:9\.6|\bNM\+\b|\bNear Mint\+\b)/i },
        { grade => '9.4', regex => qr/(?:9\.4|\bNM\b(?!\+)\b|\bNear Mint\b(?!\+))/i }, # '(?!\+)' negative lookahead to not match NM+
        { grade => '9.2', regex => qr/(?:9\.2|\bNM-\b|\bNear Mint-\b)/i },
        { grade => '9.0', regex => qr/(?:9\.0|\bVF\/NM\b|\bVery Fine\/Near Mint\b)/i },
        { grade => '8.5', regex => qr/(?:8\.5|\bVF\+\b|\bVery Fine\+\b)/i },
        { grade => '8.0', regex => qr/(?:8\.0|\bVF\b(?!\+|-)\b|\bVery Fine\b(?!\+|-))/i },
        { grade => '7.5', regex => qr/(?:7\.5|\bVF-\b|\bVery Fine-\b)/i },
        { grade => '7.0', regex => qr/(?:7\.0|\bFN\/VF\b|\bFine\/Very Fine\b)/i },
        { grade => '6.5', regex => qr/(?:6\.5|\bFN\+\b|\bFine\+\b)/i },
        { grade => '6.0', regex => qr/(?:6\.0|\bFN\b(?!\+|-)\b|\bFine\b(?!\+|-))/i },
        { grade => '5.5', regex => qr/(?:5\.5|\bFN-\b|\bFine-\b)/i },
        { grade => '5.0', regex => qr/(?:5\.0|\bVG\/FN\b|\bVery Good\/Fine\b)/i },
        { grade => '4.5', regex => qr/(?:4\.5|\bVG\+\b|\bVery Good\+\b)/i },
        { grade => '4.0', regex => qr/(?:4\.0|\bVG\b(?!\+|-)\b|\bVery Good\b(?!\+|-))/i },
        { grade => '3.5', regex => qr/(?:3\.5|\bVG-\b|\bVery Good-\b)/i },
        { grade => '3.0', regex => qr/(?:3\.0|\bGD\/VG\b|\bGood\/Very Good\b)/i },
        { grade => '2.5', regex => qr/(?:2\.5|\bGD\+\b|\bGood\+\b)/i },
        { grade => '2.0', regex => qr/(?:2\.0|\bGD\b(?!\+|-)\b|\bGood\b(?!\+|-))/i },
        { grade => '1.8', regex => qr/(?:1\.8|\bGD-\b|\bGood-\b)/i },
        { grade => '1.5', regex => qr/(?:1\.5|\bFR\/GD\b|\bFair\/Good\b)/i },
        { grade => '1.0', regex => qr/(?:1\.0|\bFR\b|\bFair\b)/i },
        { grade => '0.5', regex => qr/(?:0\.5|\bPR\b|\bPoor\b)/i },
    ];
}

=head2 getPrompt

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

sub searchEbay {
    my ($search, $max_price, $min_grade) = @_;

    my $target_year = undef;
    if ( $search =~ /\((\d{4})\)/ ) {
        $target_year = $1;
    } 
    elsif ( $search =~ /\b(\d{4})\b/ ) {
        $target_year = $1;
    }

    my $first_word_of_search_title = undef;
    if ( $search =~ /^([\w-]+)/ ) {
        $first_word_of_search_title = $1;
    }

    my $desired_issue_number = undef;
    if ( $search =~ /#\s*(\d+)/ ) {
        $desired_issue_number = $1;
    }

    my $client_id = $ENV{'EBAY_CLIENT_ID'} || 'YOUR_EBAY_CLIENT_ID_HERE';
    my $client_secret = $ENV{'EBAY_CLIENT_SECRET'} || 'YOUR_EBAY_CLIENT_SECRET_HERE';
    my $token_url = 'https://api.ebay.com/identity/v1/oauth2/token';
    my $scope = 'https://api.ebay.com/oauth/api_scope';
    my $buy_api_url = 'https://api.ebay.com/buy/browse/v1/item_summary/search';

    if ( ! defined($client_id) || $client_id eq 'YOUR_EBAY_CLIENT_ID_HERE' ) {
        die "ERROR: eBay Client ID is not set.\n\nPlease set the EBAY_CLIENT_ID environment variable or in a .env file.\n";
    }
    if ( ! defined($client_secret) || $client_secret eq 'YOUR_EBAY_CLIENT_ID_HERE' ) {
        die "ERROR: eBay Client Secret is not set.\n\nPlease set the EBAY_CLIENT_SECRET environment variable or in a .env file.\n";
    }

    my $ua = LWP::UserAgent->new;
    $ua->agent("EbaySearchScript/1.0");

    # print "Requesting OAuth2 access token from eBay...\n";

    my $token_req = HTTP::Request->new(POST => $token_url);
    $token_req->header(
        'Content-Type' => 'application/x-www-form-urlencoded',
        'Authorization' => 'Basic ' . encode_base64("$client_id:$client_secret", '')
    );
    $token_req->content("grant_type=client_credentials&scope=" . URI::Escape::uri_escape($scope));

    my $token_res = $ua->request($token_req);

    unless ($token_res->is_success) {
        die "ERROR: Failed to get OAuth2 access token: " . $token_res->status_line . "\n"
          . "Response: " . $token_res->decoded_content . "\n";
    }

    my $token_data = JSON->new->decode($token_res->decoded_content);
    my $access_token = $token_data->{access_token};

    unless ($access_token) {
        die "ERROR: 'access_token' not found in eBay's OAuth2 response.\n";
    }

    # print "Successfully obtained access token.\n\n";

    # print "Querying eBay Buy API for: \"$search\"...\n\n";

    my $request_uri = URI->new($buy_api_url);
    $request_uri->query_form(
        q => $search,
        limit => 200,
    );

    my $api_req = HTTP::Request->new(GET => $request_uri);
    $api_req->header('Authorization' => 'Bearer ' . $access_token);

    my $response = $ua->request($api_req);

    unless ($response->is_success) {
        my $error_message = "API request failed: " . $response->status_line;
        my $content = $response->decoded_content;

        if ($content) {
            try {
                my $error_data = JSON->new->decode($content);
                if ($error_data->{errors} && ref $error_data->{errors} eq 'ARRAY' && $error_data->{errors}[0]->{message}) {
                     $error_message = "eBay Buy API Error: " . $error_data->{errors}[0]->{message};
                     if ($error_data->{errors}[0]->{message} =~ /daily request limit/) {
                        $error_message .= "\n\nHint: You may have hit your daily API call limit. Please wait and try again later, or check your eBay developer account for more details.";
                     }
                }
            } catch {
                $error_message .= "\nResponse content: " . $content;
            };
        } else {
            $error_message .= "\nResponse content: None";
        }
        
        die "$error_message\n";
    }

    my $data = JSON->new->decode($response->decoded_content);

    my $items = $data->{itemSummaries} || [];
    my @filtered_items;

    if ( $items && @$items ) {
        my $filter_message = "Found " . scalar(@$items) . " listings for '$search' on eBay (originally showing top 200). Applying client-side filters (location='US', price <= $max_price";
        if (defined $target_year) {
            $filter_message .= ", year = $target_year";
        }
        if (defined $first_word_of_search_title) {
            $filter_message .= ", title starts with '" . $first_word_of_search_title . "'";
        }
        $filter_message .= ", has image, no reprints/facsimiles/detached/lot):\n\n";
        # print $filter_message;

        foreach my $item (@$items) {
            my $title = $item->{title} || 'N/A';
            my $price_value = $item->{price}{value} || 'N/A';
            my $item_country = $item->{itemLocation}{country} || 'N/A';
            my $publication_year = undef; # Use undef for no year found

            # skip if no image
            if ( ! ($item->{image} && $item->{image}{imageUrl}) ) {
                next;
            }

            if ( $title =~ /\((\d{4})\)/ ) {
                $publication_year = $1;
            } elsif ( $title =~ /\b(\d{4})\b/ ) {
                $publication_year = $1;
            }
            $item->{publicationYear} = (defined $publication_year) ? $publication_year : 'N/A';

            my $issue_number = undef;
            if ( $title =~ /#\s*(\d+)/ ) { # Prioritize # N
                $issue_number = $1;
            } 
            elsif ( $title =~ /\b(\d+)\b/ ) { # Then plain whole numbers
                my $potential_issue = $1;
                # Check if this plain number is not likely a year or already a grade
                my $is_year = (defined $publication_year && $potential_issue eq $publication_year);
                # Use $item->{grade} for comparison as it's always initialized
                $item->{grade} = '' unless $item->{grade};
                my $is_grade = ($item->{grade} ne 'N/A' && $potential_issue eq $item->{grade});

                if ( ! $is_year && ! $is_grade ) {
                    $issue_number = $potential_issue;
                }
            }
            $item->{'issueNumber'} = (defined $issue_number) ? $issue_number : 'N/A';

            my $grade = undef;
            if ( $title =~ /\b([0-9]\.\d)\b/ ) {
                $grade = $1;
            }

            if ( ! defined $grade || $grade eq 'N/A' ) {
                my $grade_mappings = _load_grade_mappings();
                foreach my $mapping (@$grade_mappings) {
                    if ( ($item->{condition} && $item->{condition} =~ $mapping->{regex}) || ($title =~ $mapping->{regex}) ) {
                        $grade = $mapping->{grade};
                        last; # Found a grade, no need to check further
                    }
                }
            }
            $item->{grade} = (defined $grade) ? $grade : 'N/A';

            # skip if min_grade is defined and item's grade is less than min_grade
            if ( defined $min_grade ) {
                # only compare if the item actually has a numeric grade
                if ( $item->{grade} ne 'N/A' && $item->{grade} < $min_grade ) {
                    next;
                }
            }

            # Skip if not located in the US
            if ( $item_country ne 'US' ) {
                next;
            }

            # Skip if target year is defined and doesn't match item's publication year
            if ( defined $target_year && defined $publication_year && $publication_year ne $target_year ) {
                next;
            }

            # Skip if item title does not contain the first word of the search title
            if ( defined $first_word_of_search_title && !(lc($title) =~ lc($first_word_of_search_title)) ) {
                next;
            }

            # Skip if desired_issue_number is defined and doesn't match item's issueNumber
            if ( defined $desired_issue_number ) { # We know $desired_issue_number is defined here
                if ( $item->{'issueNumber'} ne 'N/A' && $item->{'issueNumber'} ne $desired_issue_number ) {
                    next;
                }
            }

            if ( $title =~ /reprint|facsimile|detached| lot|choose/i ) {
                next;
            }

            if ( $price_value ne 'N/A' && $price_value <= $max_price ) {
                push @filtered_items, $item;
            }
        }
    }
    return \@filtered_items;
}


1;

