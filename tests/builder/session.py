#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
# "split" puts TODO/FIXMEs in a second start frame, as a session saved before the sidebar switcher could.
import json
import sys

from gi.repository import GLib


def load(path):
    with open(path, 'rb') as f:
        return GLib.Variant.new_from_bytes(GLib.VariantType.new('a{sv}'), GLib.Bytes.new(f.read()), False)


def items(session):
    return [session.lookup_value('items', None).get_child_value(i).get_variant()
            for i in range(session.lookup_value('items', None).n_children())]


def position(item):
    pos = item.lookup_value('position', None)
    return pos.unpack() if pos is not None else {}


def unboxed(value):
    return value.get_variant() if value is not None and value.get_type_string() == 'v' else value


def with_position(item, area, row):
    d = GLib.VariantDict.new(item)
    pos = GLib.VariantDict.new(unboxed(item.lookup_value('position', None)))
    pos.insert_value('area', GLib.Variant('s', area))
    pos.insert_value('row', GLib.Variant('u', row))
    pos.insert_value('depth', GLib.Variant('u', 0))
    d.insert_value('position', GLib.Variant('v', pos.end()))
    return d.end()


def split(path):
    session = load(path)
    out, todo = [], False
    for item in items(session):
        ident = item.lookup_value('id', None)
        if ident is not None and ident.get_string() == 'GbpTodoPanel':
            item, todo = with_position(item, 'start', 1), True
        out.append(item)
    if not todo:
        sys.exit('session.py: no TODO/FIXMEs pane in the session')
    # The sidebar's own views are not session items, so its frame is not saved: write the second one.
    frame = GLib.VariantDict.new(None)
    frame.insert_value('type-hint', GLib.Variant('s', 'PanelFrame'))
    frame.insert_value('position', GLib.Variant('v', GLib.Variant('a{sv}', {
        'area': GLib.Variant('s', 'start'), 'row': GLib.Variant('u', 1), 'column': GLib.Variant('u', 0)})))
    out.append(frame.end())
    d = GLib.VariantDict.new(session)
    d.insert_value('items', GLib.Variant('av', out))
    with open(path, 'wb') as f:
        f.write(d.end().get_data_as_bytes().get_data())


def frames(path):
    every = items(load(path))
    rows = [position(i).get('row', 0) for i in every
            if (i.lookup_value('type-hint', None) or GLib.Variant('s', '')).get_string().endswith('Frame')
            and position(i).get('area') == 'start']
    todo = [position(i).get('area') for i in every
            if (i.lookup_value('id', None) or GLib.Variant('s', '')).get_string() == 'GbpTodoPanel']
    print(json.dumps({'startRows': sorted(rows), 'todoArea': todo[0] if todo else None}))


{'split': split, 'frames': frames}[sys.argv[1]](sys.argv[2])
