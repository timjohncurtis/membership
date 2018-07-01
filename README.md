[![pipeline status](https://gitlab.com/tarantool/ib-core/membership/badges/master/pipeline.svg)](https://gitlab.com/tarantool/ib-core/membership/commits/master)

# Membership library for Tarantool based on a gossip protocol

This library builds a mesh from multiple tarantool instances. The
mesh monitors itself, helps members discover everyone else and get
notified about their status changes with low latency.

It is built upon the ideas from consul, or, more precisely,
the [SWIM](docs/swim-paper.pdf) algorithm.

Membership module works over UDP protocol and can operate
even before tarantool `box.cfg` was initialized.

## Member data structure

A member is represented by the table with fields:
* `uri`
* `status` is a string: `alive`, `suspect`, `dead` or `left`
* `incarnation` which is incremented every time the instance is being suspected or dead or updates its payload
* `payload` is a table with auxiliary data, which can be used by various modules to do whatever they want
* `timestamp` is a value of `fiber.time64()`
`timestamp` corresponds to the last update of status or incarnation.
`timestamp` is always local and does not depent on other members' clock setting.

Example:

```yaml
---
uri: localhost:33001
status: alive
incarnation: 1
payload:
    uuid: 2d00c500-2570-4019-bfcc-ab25e5096b73
timestamp: 1522427330993752
...
```

## API

- [`init(advertise_host, port)`](#membershipinitadvertise_host-port)
- [`myself()`](#membershipmyself)
- [`get_member(uri)`](#membershipget_memberuri)
- [`members()`](#membershipmembers)
- [`pairs()`](#membershippairs)
- [`add_member(uri)`](#membershipadd_memberuri)
- [`probe_uri(uri)`](#membershipprobe_uriuri)
- [`broadcast(port)`](#membershipbroadcastport)
- [`set_payload(key, value)`](#membershipset_payloadkey-value)
- [`leave()`](#membershipleave)
- [`get_encryption_key(key)`](#membershipget_encryption_keykey)
- [`set_encryption_key(key)`](#membershipset_encryption_keykey)
- [`subscribe()`](#membershipsubscribe)
- [`unsubscribe(cond)`](#membershipunsubscribecond)

### `membership.init(advertise_host, port)`

Initialize membership module.
This binds a UDP socket on `0.0.0.0:<port>` and
sets `advertise_uri = <advertise_host>:<port>`,
`incarnation = 1`.

It is possible to call `init()` several times:
the old socket will be closed and the new opened.
If `advertise_uri` is changed during `init()`, the old `advertise_uri` will be considered as `DEAD`.
In order to leave the group gracefully use function [`leave()`](#membershipleave).

Returns `true` or raises an error.

### `membership.myself()`

Returns [member data structure](#member-data-structure) describing myself.

### `membership.get_member(uri)`

Returns [member data structure](#member-data-structure) for corresponding `uri`.

### `membership.members()`

Obtain all members known to the current instance.
Editing this table has no effect.

Returns table with `uri` keys and
[member data structures](#member-data-structure) as values.

### `membership.pairs()`

This is a shorthand for `pairs(membership.members())`

### `membership.add_member(uri)`

Add member to the group and propagate this event to other members.
It is enough to add member to a single instance
and everybody else in group will receive the update with time.

It does not matter who adds whom, the result will be the same.

### `membership.probe_uri(uri)`

Send a message to the member.
The member is added to the group only if it responds.

Returns `true` if member responds within 0.2 seconds, else returns `nil, error`.

### `membership.broadcast(port)`

Discover members in local network by sending UDP broadcast message.

Address is obtained from `socket.getaddrinfo(advertise_uri)`,
broadcast is sent to destinations:

- `127.0.0.255:<port>`
- `x.255.255.255:<port>`
- `x.x.255.255:<port>`
- `x.x.x.255:<port>`

Returns `true` if broadcast was sent,
returns `false` if `getaddrifo` failed.

### `membership.set_payload(key, value)`

Update `myself().payload` and disseminate it along with member status.

It also increments `incarnation`.

Returns `true`.

### `membership.leave()`

Gracefully leave the membership group.
The node will be marked with status `left`
and no other members will ever try to connect it.

### `membership.is_encrypted()`

Returns `true` if encryption enabled.

Returns `false` if encryption disabled.

### `membership.set_encryption_key(key)`

Setup the key used for low-level message encryption.
The encryption is handled with the `crypto.cipher.aes256.cbc` tarantool module.
The `key` is either trimmed or padded automatically to be exactly 32 bytes.
When `key == nil`, the encryption is disabled.

In order for members to communicate properly,
all members must be configured to use the same encryption key.
Otherwise, members will report the status `non-decryptable`.

### `membership.get_encryption_key(key)`

Retrieve the encryption key being used.

### `membership.subscribe()`

Subsctibe for updates in members table.

Returns `fiber.cond` object, which is broadcasted whenever
members table changes.

### `membership.unsubscribe(cond)`

Remove subscription on `cond`, which was earlier obtained from
`membership.subscribe()`.

The validity of `cond` is not checked.

Returns `nil`.
