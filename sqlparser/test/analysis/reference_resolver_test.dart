import 'package:test/test.dart';
import 'package:sqlparser/sqlparser.dart';

void main() {
  test('resolves simple functions', () {
    final context = SqlEngine().analyze('SELECT ABS(-3)');

    final select = context.root as SelectStatement;
    final column = select.columns.single as ExpressionResultColumn;

    expect((column.expression as FunctionExpression).resolved, abs);
  });

  test('resolves table names and aliases', () {
    final id = Column('id');
    final content = Column('content');

    final demoTable = Table(
      name: 'demo',
      resolvedColumns: [id, content],
    );
    final engine = SqlEngine()..registerTable(demoTable);

    final context = engine.analyze('SELECT id, d.content FROM demo AS d');

    final select = context.root as SelectStatement;
    final firstColumn = select.columns[0] as ExpressionResultColumn;
    final secondColumn = select.columns[1] as ExpressionResultColumn;
    final from = select.from[0] as TableReference;

    expect((firstColumn.expression as Reference).resolved, id);
    expect((secondColumn.expression as Reference).resolved, content);
    expect(from.resolved, demoTable);
  });
}