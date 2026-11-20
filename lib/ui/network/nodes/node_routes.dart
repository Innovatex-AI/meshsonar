// How other screens open a node or observer page of the Network tab (AZ-3.4).
import 'package:flutter/material.dart';

import 'node_screen.dart';
import 'observer_screen.dart';

/// Opens the node page for [nodeKey] (64 hex) on the region host [baseUrl].
void openNetworkNode(BuildContext context, {required String baseUrl, required String regionSlug, required String nodeKey}) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NetworkNodeScreen(baseUrl: baseUrl, regionSlug: regionSlug, nodeKey: nodeKey.toLowerCase())));
}

/// Opens the observer page for [observerId] (a 64-hex key, or `<sourceId>:<id>` for an outside observer).
void openNetworkObserver(BuildContext context, {required String baseUrl, required String regionSlug, required String observerId}) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NetworkObserverScreen(baseUrl: baseUrl, regionSlug: regionSlug, observerId: observerId)));
}
