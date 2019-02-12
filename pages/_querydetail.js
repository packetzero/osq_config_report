
//var schemaUrl="https://www.osquery.io/schema/3.3.0#";

function addSchemaLinks() {
  jQuery('div.tableref').wrap(function() {
    return "<a target=_blank href='https://www.osquery.io/schema/3.3.0#" + $( this ).text() + "'></a>";
  });

}

jQuery(document).ready(function() {
  addSchemaLinks();
});
