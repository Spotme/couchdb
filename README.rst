Apache CouchDB README
=====================

SpotMe for of Apache CouchDB

Patches (not a full list)
------------- 

### 1. Support for `validate_doc_read` functions (JS and native Erlang ones).

CouchDB already has support for [validate_doc_update](http://docs.couchdb.org/en/master/ddocs/ddocs.html#validate-document-update-functions) functions which if defined in the design doc can be used to prevent invalid or unauthorised document update requests from being stored. In other words document-level write security. This patch further enhances security via adding a fine-grained document-level read security. Patch implements a support for `validate_doc_read` functions.

### NB
`validate_doc_read` has a bit different semantics when is used together with `_bulk_get`. Normally for a single GET request which violates VDR rules the response will be `403 Forbidden`. But when the forbidden document is requested as a part of `{"id", "rev"}` batch in the `_bulk_get` CouchDB instead of throwing an error for the whole batch returns a so-called "stub" of the forbidden document which always has `validate_doc_read_error` field the value of which is `"forbidden"` and optionally a detailed description and the VDR error code.
```
"_id" : "id",
"_rev": "rev",
"validate_doc_read_error":"forbidden",
"forbidden":"not allowed (error code 104), DocId: 032d9670-ee8f-427c-9a44-e0a77bb725fc Rev: 1-7a48478d435872b71dd2929f3439b213"
```
This was done because VDR is a custom SpotMe patch which is not accepted to upstream Apache CouchDB but `_bulk_get` patch has been accepted. Therefore due to obvious reasons changing `_bulk_get` handler logic to filter out those stubs is not acceptable. When VDR patch design was discussed the core idea was to avoid intrusiveness at all costs. That's why not using the concept of document stubs and throwing an exception early internally also is not possible for the reason this breaks a lot of different internal code paths and will require massive and unrelated code changes in the CouchDB's storage engine due to the fact it wasn't designed with the assumption that internal lookup functions may have side-effects. On the other hand changing VDR response for a single GET request to also return a "stub" document breaks [CouchDB API contracts](https://docs.couchdb.org/en/stable/query-server/protocol.html#forbidden) for validate functions. Hence having these stubs was the only viable trade-off.

### Performance notes
These functions have to be implemented only in Erlang in order to be executed inside of `couch_native_process`, otherwise implemented in JS they will lay waste to overall performance. Currently CouchDB sends all JS map functions in the design documents to the `couch_query_server` which spawns a pool of external `couch_js` OS processes (by default `proc_manager` spawns one OS process per design doc). This involves serialising/deserialising and sending strings back and forth via a slow standard I/O. And we know that the biggest complain about standard I/O is the performance impact from double copy (standard IO buffer -> kernel -> IO buffer). On the contrary, Erlang implementation of the VDR functions have almost zero overhead, because now map function will directly go to the `couch_native_process` which will tokenise (`erl_scan`), parse (`erl_parse`), call `erl_eval` and run a function.

Optimisations for Erlang validate_doc_update and validate_doc_read to leverage caching for evaluated BEAM code have been implemented as a separate SpotMe patch.

### 2. Support for an indexed view-filtered changes feed.

Changes feed with [_view filter](http://docs.couchdb.org/en/2.2.0/api/database/changes.html#view) allows to use existing map function as the filter, but unfortunately it doesn’t query the view index files. Fortunately enough CouchDB's `mrview` has unused internal implementation of two separate B+ tree indexes namely: `Seq` and `KeyBySeq` which are responsible for indexing of the changes feed with view keys. This functionality marked as `fast_view` was never exposed to `fabric` cluster layer and `chttpd` API, because it has its own problems. Long story short, it appears to work in some simple cases, but quickly goes south once keys in views starting to be removed and then reappear. For instance when the same keys appear in a view, then removed with docs updated or deleted and then reappearing again with new updates, the `seq`-index breaks pretty quickly. Also another problem is that unlike DB's b-tree keys that are always strings, views keys in seq b-tree could be anything, so sorting might potentiall yield unexpected results. `Seq` index currently looks like this: `{UpdSeq, ViewKey} -> {DocID, EmittedValue, DocRev}`. Where `UpdSeq` number is the sum of the individual update sequences encoded in the second part of update sequence as base64. And `ViewKey` can be any mapped from JSON data type: binary, integer, float or boolean. Currently `mrview` uses Erlang native collation to find first key to start from, so consistent low limit key couldn't be constructed.
According to discussions in the dev-mailing list, hidden `seq` and `keyseq` indexes support will be completely removed in future and will be reimplemented from scratch. But nevertheless `seq`/`keyseq`-indexed changes feed proved to work for simple controlled scenarios. As a result aforementioned functionality has been extended in this fork and some bugs have been fixed (compaction of `seq`-indexes, b-tree reduce, some replication scenarios) and new functionality has been implemented namely: view-filtered replication with rcouch, support for custom `/_last_seq` and `_view/_info` endpoints and `fabric` interface to the underlying `mrview`'s `seq`/`keyseq`-indexes.
Additional `KeyBySeq` index allows to apply familiar view query params to changes feed such as `key`, `start_key`, `end_key`, `limit` and so on which allow to have a somewhat limited [channel-like](https://developer.couchbase.com/documentation/mobile/current/guides/sync-gateway/channels/index.html#introduction-to-channels) functionality in vanilla Apache CouchDB.


### 3. Support for bulk get with multipart response

**UPD** This functionality has been submitted to the upstream repo in this [PR](https://github.com/apache/couchdb/pull/1195) and hopefully will be merged soon. PR also has a detailed description and motivation of the feature.


Documentation
-------------

We have documentation:

    http://docs.couchdb.org/

It includes a changelog:

    http://docs.couchdb.org/en/latest/whatsnew/

For troubleshooting or cryptic error messages, see:

    http://docs.couchdb.org/en/latest/install/troubleshooting.html

For general help, see:

     http://couchdb.apache.org/#mailing-list
     
We also have an IRC channel:

    http://webchat.freenode.net/?channels=couchdb

The mailing lists provide a wealth of support and knowledge for you to tap into.
Feel free to drop by with your questions or discussion. See the official CouchDB
website for more information about our community resources.

Verifying your Installation
---------------------------

Run a basic test suite for CouchDB by browsing here:

    http://127.0.0.1:5984/_utils/#verifyinstall

Getting started with developing
-------------------------------

For more detail, read the README-DEV.rst file in this directory.

Basically you just have to install the needed dependencies which are
documented in the install docs and then run ``./configure && make``.

You don't need to run ``make install`` after compiling, just use
``./dev/run`` to spin up three nodes. You can add haproxy as a caching
layer in front of this cluster by running ``./dev/run --with-haproxy
--haproxy=/path/to/haproxy`` . You will now have a local cluster
listening on port 5984.

For Fauxton developers fixing the admin-party does not work via the button in
Fauxton. To fix the admin party you have to run ``./dev/run`` with the ``admin``
flag, e.g. ``./dev/run --admin=username:password``. If you want to have an
admin-party, just omit the flag.

Contributing to CouchDB
-----------------------

You can learn more about our contributing process here:

    https://github.com/apache/couchdb/blob/master/CONTRIBUTING.md

Cryptographic Software Notice
-----------------------------

This distribution includes cryptographic software. The country in which you
currently reside may have restrictions on the import, possession, use, and/or
re-export to another country, of encryption software. BEFORE using any
encryption software, please check your country's laws, regulations and policies
concerning the import, possession, or use, and re-export of encryption software,
to see if this is permitted. See <http://www.wassenaar.org/> for more
information.

The U.S. Government Department of Commerce, Bureau of Industry and Security
(BIS), has classified this software as Export Commodity Control Number (ECCN)
5D002.C.1, which includes information security software using or performing
cryptographic functions with asymmetric algorithms. The form and manner of this
Apache Software Foundation distribution makes it eligible for export under the
License Exception ENC Technology Software Unrestricted (TSU) exception (see the
BIS Export Administration Regulations, Section 740.13) for both object code and
source code.

The following provides more details on the included cryptographic software:

CouchDB includes a HTTP client (ibrowse) with SSL functionality.
