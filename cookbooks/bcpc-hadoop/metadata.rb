name             'bcpc-hadoop'
maintainer       'Bloomberg Finance L.P.'
maintainer_email 'compute@bloomberg.net'
license          'Apache License 2.0'
description      'Installs/Configures Bloomberg Clustered Private Hadoop Cloud (BCPHC)'
long_description IO.read(File.join(File.dirname(__FILE__), 'README.md'))
version          '0.1.0'

depends 'bcpc', '>= 0.5.0'
depends 'java', '>= 1.28.0'
depends 'maven', '>= 2.0.0'
depends 'pam'
depends 'sysctl'
depends 'ulimit'
