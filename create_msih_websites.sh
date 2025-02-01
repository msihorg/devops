#!/bin/bash

for env in foodworker electionsurvey gd4 arbitrationclauses arbitrationtransparency nurturingcapitalism studentresearchprojects; do
    echo sudo ./create_website.sh $env
done

# sudo ./create_website.sh foodworker
sudo ./create_website.sh electionsurvey
# sudo ./create_website.sh gd4
# sudo ./create_website.sh arbitrationclauses
sudo ./create_website.sh arbitrationtransparency
sudo ./create_website.sh nurturingcapitalism
sudo ./create_website.sh studentresearchprojects