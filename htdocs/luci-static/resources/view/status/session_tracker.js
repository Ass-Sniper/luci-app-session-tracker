'use strict';
'require ui';
'require rpc';
'require view';
'require poll';

var callGetTerminals = rpc.declare({
	object: 'session.tracker',
	method: 'get_terminals',
	expect: { '': {} }
});

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return callGetTerminals();
	},

	render: function(data) {
		function formatDuration(seconds) {
			seconds = Math.max(0, Number(seconds) || 0);

			var d = Math.floor(seconds / 86400);
			var h = Math.floor((seconds % 86400) / 3600);
			var m = Math.floor((seconds % 3600) / 60);
			var s = seconds % 60;
			var res = [];

			if (d > 0) res.push(_('%d d').format(d));
			if (h > 0) res.push(_('%d h').format(h));
			if (m > 0) res.push(_('%d min').format(m));
			if (s > 0 || res.length === 0) res.push(_('%d s').format(s));

			return res.join(' ');
		}

		var table = E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('IP Address')),
				E('th', { 'class': 'th' }, _('MAC Address')),
				E('th', { 'class': 'th' }, _('Hostname')),
				E('th', { 'class': 'th' }, _('Interface')),
				E('th', { 'class': 'th' }, _('Status')),
				E('th', { 'class': 'th' }, _('Online Duration'))
			])
		]);

		function renderTableRows(terminalsData) {
			var terminals = (terminalsData && terminalsData.terminals) ? terminalsData.terminals : [];

			while (table.rows.length > 1)
				table.deleteRow(1);

			if (terminals.length === 0) {
				table.appendChild(E('tr', { 'class': 'tr placeholder' }, [
					E('td', { 'class': 'td', 'colspan': '6' }, _('No active terminals found.'))
				]));
			}
			else {
				terminals.forEach(function(dev) {
					var statusBadge;

					if (dev.status === 'REACHABLE')
						statusBadge = E('span', { 'class': 'badge label success' }, _('Active'));
					else if (dev.status === 'STALE')
						statusBadge = E('span', { 'class': 'badge label warning' }, _('Stale (Grace)'));
					else
						statusBadge = E('span', { 'class': 'badge label' }, _(dev.status || 'Unknown'));

					var hostnameText = dev.hostname;
					if (!hostnameText || hostnameText === '(Static IP)')
						hostnameText = _('(Static IP)');

					table.appendChild(E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, dev.ip || '-'),
						E('td', { 'class': 'td' }, E('code', {}, dev.mac || '-')),
						E('td', { 'class': 'td' }, hostnameText),
						E('td', { 'class': 'td' }, dev.dev || '-'),
						E('td', { 'class': 'td' }, statusBadge),
						E('td', { 'class': 'td' }, formatDuration(dev.session_time_sec))
					]));
				});
			}
		}

		renderTableRows(data);

		poll.add(function() {
			return callGetTerminals().then(function(newData) {
				renderTableRows(newData);
			});
		}, 5);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Active Terminal Sessions')),
			E('div', { 'class': 'cbi-map-descr' }, _('Real-time tracking of online LAN terminals and session duration.')),
			E('div', { 'class': 'cbi-section' }, [ table ])
		]);
	}
});
