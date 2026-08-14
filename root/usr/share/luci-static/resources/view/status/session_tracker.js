'use strict';
'require ui';
'require rpc';
'require view';

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
		var terminals = (data && data.terminals) ? data.terminals : [];

		function formatDuration(seconds) {
			if (!seconds || seconds <= 0) return '0s';
			var d = Math.floor(seconds / 86400);
			var h = Math.floor((seconds % 86400) / 3600);
			var m = Math.floor((seconds % 3600) / 60);
			var s = seconds % 60;

			var res = [];
			if (d > 0) res.push(d + 'd');
			if (h > 0) res.push(h + 'h');
			if (m > 0) res.push(m + 'm');
			if (s > 0 || res.length === 0) res.push(s + 's');
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

		if (terminals.length === 0) {
			table.appendChild(
				E('tr', { 'class': 'tr placeholder' }, [
					E('td', { 'class': 'td', 'colspan': '6' }, _('No active terminals found.'))
				])
			);
		} else {
			terminals.forEach(function(dev) {
				var statusBadge;
				if (dev.status === 'REACHABLE') {
					statusBadge = E('span', { 'class': 'badge label success' }, _('Active'));
				} else if (dev.status === 'STALE') {
					statusBadge = E('span', { 'class': 'badge label warning' }, _('Stale (Grace)'));
				} else {
					statusBadge = E('span', { 'class': 'badge label' }, dev.status || 'Unknown');
				}

				table.appendChild(
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, dev.ip || '-'),
						E('td', { 'class': 'td' }, E('code', {}, dev.mac || '-')),
						E('td', { 'class': 'td' }, dev.hostname || '(Static IP)'),
						E('td', { 'class': 'td' }, dev.dev || '-'),
						E('td', { 'class': 'td' }, statusBadge),
						E('td', { 'class': 'td' }, formatDuration(dev.session_time_sec))
					])
				);
			});
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Active Terminal Sessions')),
			E('div', { 'class': 'cbi-map-descr' }, _('Real-time tracking of online LAN terminals and session duration.')),
			E('div', { 'class': 'cbi-section' }, [ table ])
		]);
	}
});
