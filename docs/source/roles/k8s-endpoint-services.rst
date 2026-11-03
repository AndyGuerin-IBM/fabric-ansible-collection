..
.. SPDX-License-Identifier: Apache-2.0
..

k8s_endpoint_services -- Create one Service per endpoint for the nodes that are not exposed
===========================================================================================

.. contents::
   :local:
   :depth: 1

What the role does
------------------

This is an internal role. The ``endorsing_organization`` and ``ordering_organization`` roles include it for each component that is not exposed: ``expose_ca``, ``expose_peer`` or ``expose_orderer`` set to ``false``. When everything is exposed (the default), the role is never used and the organization roles need neither a kubeconfig nor the ``kubernetes`` Python library.

The Fabric operator writes ``<fqdn>:443`` for every endpoint of every node: in the custom resources, in the connection profiles and in the entries of the console. A node has several endpoints, and a Service port maps ``443`` to exactly one container port. The operator's own Service of a node cannot serve them all: ``443`` mapped to the peer port would send the ``operations`` endpoint to the gRPC port. So, for each endpoint of each node, the role creates a ClusterIP Service that maps ``443`` to the native port of that endpoint. The Services of the operator are never modified.

The role creates the Services before the module call that creates the node, because that module waits for the ``/healthz`` endpoint of the node. After the call, the organization roles use the role again to check that every URL returned by the console has a Service.

Services created
----------------

.. list-table::
   :header-rows: 1
   :widths: 20 20 20

   * - Component
     - Endpoint
     - Native port
   * - Certificate authority
     - ``ca``
     - ``7054``
   * - Certificate authority
     - ``operations``
     - ``9443``
   * - Peer
     - ``peer``
     - ``7051``
   * - Peer
     - ``operations``
     - ``9443``
   * - Peer
     - ``grpcweb``
     - ``7443``
   * - Ordering node
     - ``orderer``
     - ``7050``
   * - Ordering node
     - ``admin``
     - ``9443``
   * - Ordering node
     - ``operations``
     - ``8443``
   * - Ordering node
     - ``grpcweb``
     - ``7443``

Each Service listens on port ``443`` only.

Names of the Services
---------------------

The operator builds the name of an endpoint as ``<namespace>-<cr_name>-<endpoint>.<domain>``. The role names each Service after the first label of that name:

::

    Service name:  <namespace>-<cr_name>-<endpoint>
    Service FQDN:  <namespace>-<cr_name>-<endpoint>.<namespace>.svc.<cluster_domain>

When ``hlf_network_domain`` is the cluster domain, the names built by the operator are these Service FQDNs, and nothing else is needed to resolve them. Otherwise, the cluster DNS must rewrite the names of the endpoints to these Services.

The ``<cr_name>`` is the name of the custom resource that the operator creates for the node. The console chooses it from the display name of the component, so the role works it out with two rules:

- The display name in lower case, with every character that matches ``k8s_endpoint_services_cr_name_regex`` removed: ``Org1 CA`` gives ``org1ca``. With several peers, the number is added to the display name first: ``org1peer1``, ``org1peer2``.
- For an ordering service, the name of its nodes is the name above, then ``k8s_endpoint_services_orderer_node_suffix``, then the number of the node: ``orderingservicenode1``.

These rules are assumptions, so the role checks them: after the module call, every URL returned by the console must have a Service. When one does not, the role fails and prints the name that the console really chose.

On a rerun, the node exists already, so its ``<cr_name>`` is read from its URL instead: the organization roles get the node with ``certificate_authority_info``, ``peer_info`` or ``ordering_service_info`` before they create the Services, and pass its URL in ``k8s_endpoint_services_existing_urls``. They do the same before they delete a node, so that the delete tasks find its Services.

Ingresses of the nodes
----------------------

The operator also creates an nginx Ingress for every node, and has no setting to turn it off. Even when a node is not exposed, nginx still forwards a client that sends the right host name. With ``neutralize_node_ingresses: true``, the organization roles run the role with ``tasks_from: neutralize_ingress`` after each module call, for each component that is not exposed. These tasks set ``spec.ingress.class`` of the custom resource of each node to ``unexposed_ingress_class`` (``none`` by default), a class that no controller serves, and wait until the operator has rebuilt the Ingresses with that class. The Ingress is kept, but nginx no longer serves it. The pods of a CA and of an ordering node are not restarted; the operator rolls out a new pod for a peer, and the tasks wait until it is ready.

The names of the custom resources are read from the URLs returned by the module call. Between the creation of a node and this change, its endpoints can be reached through nginx.

Role variables
--------------

You can override these variables in your playbook. The organization roles set the first four and ``k8s_endpoint_services_existing_urls``.

.. list-table::
   :header-rows: 1
   :widths: 32 14 54

   * - Variable
     - Default
     - Effect
   * - ``k8s_endpoint_services_namespace``
     - ``""``
     - The namespace of the console and of the nodes.
   * - ``k8s_endpoint_services_component``
     - ``""``
     - The kind of component: ``ca``, ``peer`` or ``orderer``.
   * - ``k8s_endpoint_services_display_name``
     - ``""``
     - The display name of the component, from which the name of its custom resources is worked out.
   * - ``k8s_endpoint_services_count``
     - ``1``
     - The number of peers or of ordering nodes.
   * - ``k8s_endpoint_services_cr_names``
     - ``[]``
     - The names of the custom resources, one per node. When empty, they are worked out from the display name. Set it to give the names yourself.
   * - ``k8s_endpoint_services_existing_urls``
     - ``[]``
     - One URL per node, in node order, for the nodes that exist already: an empty string for a node not created yet. The name of the custom resource of an existing node is read from its URL.
   * - ``k8s_endpoint_services_cr_name_regex``
     - ``[^a-z0-9]``
     - The characters removed from the display name to get the name of a custom resource.
   * - ``k8s_endpoint_services_orderer_node_suffix``
     - ``node``
     - The text between the name of an ordering service and the number of its node.
   * - ``k8s_endpoint_services_selector_key``
     - ``app``
     - The label of the pods that carries the name of the custom resource. The Services select the pods with it.
   * - ``k8s_endpoint_services_endpoints``
     - see above
     - The endpoints of each component and the native port of each one.
   * - ``k8s_endpoint_services_urls``
     - ``[]``
     - The URLs returned by the module call, to check when the role runs with ``tasks_from: verify``, and to read the names of the custom resources from with ``tasks_from: neutralize_ingress``.
   * - ``k8s_endpoint_services_ingress_class``
     - ``none``
     - The Ingress class set on the custom resources of the nodes with ``tasks_from: neutralize_ingress``. The organization roles pass ``unexposed_ingress_class``.
   * - ``k8s_endpoint_services_wait_timeout``
     - ``600``
     - The number of seconds that ``tasks_from: neutralize_ingress`` waits for the nodes to be ready again.

The Services carry the label ``app.kubernetes.io/managed-by: fabric-ansible-collection``, so you can list them:

::

    kubectl get svc -n <namespace> -l app.kubernetes.io/managed-by=fabric-ansible-collection

The delete tasks of the organization roles remove them with ``tasks_from: delete``.
