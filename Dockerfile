FROM ubuntu:latest

RUN apt-get update -y 
RUN apt-get install -y wget gnupg2
RUN wget -q -O - https://packages.cloudfoundry.org/debian/cli.cloudfoundry.org.key | apt-key add -
RUN echo "deb https://packages.cloudfoundry.org/debian stable main" | tee /etc/apt/sources.list.d/cloudfoundry-cli.list
RUN apt-get update -y 
RUN apt-get install cf8-cli jq -y
RUN wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
RUN chmod a+x /usr/local/bin/yq

RUN cf install-plugin https://github.com/AlexF4Dev/cf-run-and-wait/releases/download/0.3/cf-run-and-wait_0.3_linux_amd64 -f

ADD entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]