# Version scheme

This describes how a build's two version strings are composed. The examples are
`qcom-next` specific: another variant substitutes its own name and Debian
revision stub, and a variant built from a differently-shaped tag would need its
own derivation.

A build produces two version strings, and they are deliberately not the same
string:

```text
uname -r         7.2.0-rc7+qcom-next-20260821-gabcdef123456
Debian version   7.2.0~rc7+git20260821~gabcdef123456-0qli1~bpo13+1
```

They carry the same four facts — upstream kernel version, snapshot date,
same-day respin, commit — but they are read by two different comparators with
two different sets of rules, and each string is spelled for its own.

## What the fields mean

Both strings are derived from the tag and HEAD together, by
`ci/scripts/derive-localversion.sh`:

```text
qcom-next-7.2-rc7-20260821  @ abcdef123456…
          │       │
          │       └── snapshot: 20260821, optionally .<respin>
          └────────── upstream kernel version: 7.2.0-rc7
```

The **snapshot date** orders builds. The **respin ordinal** separates two tags
cut on the same day. The **commit** orders nothing — two SHAs have no relation —
and exists only so that a moved tag cannot produce two different kernels under
one version. It therefore comes last in both strings, after everything that does
carry ordering.

There is no `.0` on the first tag of a day. Both comparators read an absent
ordinal as lower than a present one, so the respin already sorts above it, and
the version stays closer to the tag it came from.

## Kernel release

```text
<base>+qcom-next-<date>[.<respin>]-g<12 hex>
```

The full upstream version survives here, `-rc7` included: `uname -r` is the
first thing in a bug report, and it is what says whether the reporter is on a
release candidate or a stable sublevel.

The suffix joins with `+`, not `-`. systemd compares the separator before the
chunk behind it, and `-` sorts below `+`, so `+` puts every release candidate
below the final release that follows it. Joining with `-` instead falls through
to a plain comparison of `rc` against `qcom`, where `r` > `q`, and every rc
outranks its own final release in the boot menu. This is the same trick Debian's
own kernels use (`linux-image-7.1.10+deb14-amd64`).

The variant name is part of the string, so a flavour is a distinct kernel that
installs alongside the others rather than replacing them:

```text
7.2.0-rc7+qcom-next-debug-20260821-gabcdef123456
```

This string is also the versioned binary package name
(`linux-image-<kernel release>`), so a new commit means a new package name. That
is intended: it is what lets several builds coexist, and what makes the commit
recoverable from an archive listing.

## Debian version

```text
<base>+git<date>[.<respin>]~g<12 hex>-<revision>
```

`-rcN` becomes `~rcN`, because dpkg reads `~` as "sorts below", giving
`7.2.0~rc7 < 7.2.0`. Spelled `-rc7` it would sort *above* the release it
precedes.

The snapshot is spelled `+git<date>` in Debian's usual idiom for a VCS snapshot.

The commit joins with `~`, and this is the part most likely to look like a typo.
dpkg alternates digit and non-digit runs and reads an exhausted run as lower
than a letter, so joining with `.` decides the comparison before ever reaching
the respin ordinal:

```text
7.2.0+git20260826.g3f2f3ca1a81e  >  7.2.0+git20260826.1.gabcdef123456
```

— the respin sorting *below* the build it respins. `~` sorts below everything,
including the empty string, so the ordinal is always compared first and the SHA
only ever breaks a tie between builds that share a snapshot. The alternative,
spelling `.0` on every non-respin build, buys the same ordering at the cost of a
redundant ordinal in every version forever.

The cost of `~` is one misleading reading: the version sorts below the same
snapshot without a SHA, as though it preceded it. Nothing occupies that slot,
because every snapshot build carries a SHA.

The revision (`0qli1~bpo13+1`) is not derived. Each matrix entry states its own
outright, and it says two things: where the suite belongs relative to the other
suites, and which packaging built it. The `~bpo13+1` is the backports
convention, sorting a trixie build below a forky build of the same kernel; the
trailing digit on the `0qli` stub is the packaging revision, bumped when the
packaging changes but the kernel snapshot does not. See the matrix
documentation in the top-level [README](../README.md#matrix-model).

Nothing in the revision marks how far a build has got. A kernel is built once
and the artifact that build produced is what any archive holds, so there is no
second version for a marker to sort against.

## Ordering

The full chain for one suite, in the order dpkg sorts it:

```text
7.2.0~rc7+git20260820.1~g011a82096bee-0qli1~bpo13+1     first tag of the 20th
7.2.0~rc7+git20260820.2~g3f2f3ca1a81e-0qli1~bpo13+1     respin, same day
7.2.0~rc7+git20260821~gabcdef123456-0qli1~bpo13+1       next snapshot
7.2.0~rc7+git20260821~gabcdef123456-0qli2~bpo13+1       packaging rebuild
7.2.0+git20260902~g123456789abc-0qli1~bpo13+1           7.2 final
```

## Moved tags

If an upstream tag is re-cut against a different commit, the SHA changes and so
does the version, so the two builds cannot be mistaken for each other. But
nothing guarantees the replacement sorts *above* the original — two hashes have
no order — so apt may not offer it as an upgrade:

```text
7.2.0~rc7+git20260821~g011a82096bee-0qli1~bpo13+1   original
7.2.0~rc7+git20260821~gabcdef123456-0qli1~bpo13+1   retagged; happens to sort above
7.2.0~rc7+git20260821~g0009f3c1d2e4-0qli1~bpo13+1   retagged; sorts BELOW, no upgrade
```

Whether it lands above or below is down to the hex, so treat a moved tag as
needing a version bump of its own — the respin ordinal, or the packaging
revision:

```text
7.2.0~rc7+git20260821.1~g0009f3c1d2e4-0qli1~bpo13+1   supersedes it either way
```

## Branch-tip builds

A build from a branch rather than a tag has no tag date, so the date comes from
the HEAD commit instead. The result has the same shape as a tag build and orders
in the same sequence:

```text
uname -r         7.2.0-rc7+qcom-next-20260904-g07f50dc44edd
Debian version   7.2.0~rc7+git20260904~g07f50dc44edd-0qli1~bpo13+1
```

It is the *committer* date of the commit, not the time the build ran. That means
rebuilding a commit reproduces its version instead of inventing a higher one,
and the date describes the source rather than when CI happened to start. Author
dates are not used, because a backported patch can carry one months old.

The catch is that a build clock only ever moves forwards, and a commit date does
not. If the branch is rewound to an older commit, the next build's version goes
*down*, and apt will not offer it as an upgrade. That is arguably the honest
answer — older source, older version — but it is the one case where dating by
the clock would behave differently.

## What is not in the version

The version strings name the commit, but not the tree it came from. The
repository, the resolved ref and the full 40-character SHA are recorded in the
package changelog instead:

```text
  * Kernel version: 7.2.0-rc7+qcom-next-20260904-g07f50dc44edd
  * Source: https://github.com/qualcomm-linux/kernel qcom-next
  * Commit: 07f50dc44edd…
```

so `apt changelog` on an installed image is enough to find the exact source.
