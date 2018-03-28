package = 'membership'
version = 'scm-1'
source  = {
    url = '/dev/null',
}
dependencies = {
    'tarantool',
    'lua >= 5.1',
    'checks ~> 1.0',
}

build = {
    type = 'none';
    install = {
        lua = {
            ['membership.init'] = 'membership.lua';
            ['membership.events'] = 'membership/events.lua';
            ['membership.members'] = 'membership/members.lua';
            ['membership.options'] = 'membership/options.lua';
        }
    }
}